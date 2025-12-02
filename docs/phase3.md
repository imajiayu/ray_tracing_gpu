# Phase 3: BVH 加速结构

**目标**: 实现 GPU 友好的 BVH 加速，大幅提升复杂场景性能
**时间**: 预计 4-5 天
**状态**: 📋 准备开始

---

## 概述

Phase 3 将实现 BVH (Bounding Volume Hierarchy) 加速结构，这是光线追踪中最重要的性能优化技术。目前的 Final Scene 渲染时间为 9.1 秒，通过 BVH 加速预计可降至 500ms 以内，**加速比 18×**。

**核心任务**:
1. 实现 AABB (Axis-Aligned Bounding Box) 包围盒
2. CPU 端构建 BVH 树（SAH 分割）
3. 扁平化 BVH 为线性数组（FlatBVH）
4. GPU 端迭代式 BVH 遍历
5. 优化内存布局和数据结构

---

## 任务分解

### Task 3.1: 实现 AABB 包围盒 (Day 1)

**目标**: 实现轴对齐包围盒及相交测试

**参考文件**:
- `~/ray_tracing/include/acceleration/aabb.h`

#### 具体步骤

1. **CPU 端** - `Acceleration/AABB.swift`

```swift
import simd

/// 轴对齐包围盒
struct AABB {
    var min: Point3  // 最小点
    var max: Point3  // 最大点

    // MARK: - 初始化

    init() {
        self.min = Point3(Float.infinity, Float.infinity, Float.infinity)
        self.max = Point3(-Float.infinity, -Float.infinity, -Float.infinity)
    }

    init(min: Point3, max: Point3) {
        self.min = min
        self.max = max
    }

    // MARK: - 包围盒操作

    /// 合并两个包围盒
    static func merge(_ box1: AABB, _ box2: AABB) -> AABB {
        return AABB(
            min: simd_min(box1.min, box2.min),
            max: simd_max(box1.max, box2.max)
        )
    }

    /// 包围盒表面积（用于 SAH）
    var surfaceArea: Float {
        let d = max - min
        return 2.0 * (d.x * d.y + d.y * d.z + d.z * d.x)
    }

    /// 最长轴
    var longestAxis: Int {
        let d = max - min
        if d.x > d.y && d.x > d.z {
            return 0  // X轴
        } else if d.y > d.z {
            return 1  // Y轴
        } else {
            return 2  // Z轴
        }
    }

    // MARK: - 转换为 GPU 数据

    func toGPU() -> GPUAABB {
        return GPUAABB(min: min, padding1: 0, max: max, padding2: 0)
    }
}

// MARK: - 几何体包围盒扩展

extension Sphere {
    func boundingBox() -> AABB {
        let r = SIMD3<Float>(radius, radius, radius)
        return AABB(min: center - r, max: center + r)
    }
}

extension Quad {
    func boundingBox() -> AABB {
        // Quad 的 4 个角点
        let corners = [
            corner,
            corner + sideA,
            corner + sideB,
            corner + sideA + sideB
        ]

        var box = AABB()
        for c in corners {
            box.min = simd_min(box.min, c)
            box.max = simd_max(box.max, c)
        }

        // 扩展一点点避免退化
        let delta = SIMD3<Float>(0.0001, 0.0001, 0.0001)
        box.min -= delta
        box.max += delta

        return box
    }
}
```

2. **GPU 数据结构** - `GPU/GPUStructs.swift`

```swift
/// GPU AABB（32 bytes 对齐）
struct GPUAABB {
    var min: SIMD3<Float>   // 12 bytes
    var padding1: Float     // 4 bytes
    var max: SIMD3<Float>   // 12 bytes
    var padding2: Float     // 4 bytes
}  // Total: 32 bytes
```

3. **GPU 端** - `Shaders/Common/Acceleration.metal`

```metal
/// GPU AABB（与 Swift 对齐）
struct GPUAABB {
    float3 min;
    float padding1;
    float3 max;
    float padding2;
};

/// 光线-AABB 相交测试（优化版）
/// 参考：Amy Williams et al. "An Efficient and Robust Ray–Box Intersection Algorithm"
inline bool aabb_hit(
    GPUAABB box,
    Ray r,
    float t_min,
    float t_max
) {
    // 使用倒数避免除法
    float3 inv_dir = 1.0f / r.direction;

    // 对每个轴计算交点参数
    float3 t0 = (box.min - r.origin) * inv_dir;
    float3 t1 = (box.max - r.origin) * inv_dir;

    // 处理负方向
    float3 tmin = min(t0, t1);
    float3 tmax = max(t0, t1);

    // 找到所有轴的交集
    float t_enter = max(max(tmin.x, tmin.y), tmin.z);
    float t_exit = min(min(tmax.x, tmax.y), tmax.z);

    // 检查是否有效相交
    return (t_enter < t_exit) && (t_exit > t_min) && (t_enter < t_max);
}
```

**验收标准**:
- ✅ Sphere AABB 计算正确
- ✅ Quad AABB 计算正确
- ✅ AABB 相交测试通过单元测试

---

### Task 3.2: CPU 端 BVH 构建 (Day 2)

**目标**: 实现 SAH 分割的 BVH 树构建

**参考文件**:
- `~/ray_tracing/include/acceleration/bvh.h`

#### 具体步骤

1. **BVH 节点** - `Acceleration/BVHNode.swift`

```swift
/// BVH 树节点（CPU 端）
class BVHNode {
    var bbox: AABB
    var left: BVHNode?
    var right: BVHNode?
    var geometryIndices: [UInt32]  // 叶节点存储几何体索引

    var isLeaf: Bool {
        return left == nil && right == nil
    }

    init(bbox: AABB, indices: [UInt32]) {
        self.bbox = bbox
        self.geometryIndices = indices
        self.left = nil
        self.right = nil
    }
}
```

2. **BVH 构建器** - `Acceleration/BVHBuilder.swift`

```swift
class BVHBuilder {
    private let maxLeafSize = 4  // 叶节点最大几何体数量

    /// 构建 BVH 树
    /// - Parameter geometries: 几何体数组（支持 Sphere 和 Quad）
    /// - Returns: BVH 根节点
    func build(spheres: [Sphere], quads: [Quad]) -> BVHNode {
        // 1. 计算所有几何体的包围盒
        var bboxes: [AABB] = []
        var indices: [UInt32] = []

        for (i, sphere) in spheres.enumerated() {
            bboxes.append(sphere.boundingBox())
            indices.append(UInt32(i))
        }

        for (i, quad) in quads.enumerated() {
            bboxes.append(quad.boundingBox())
            indices.append(UInt32(spheres.count + i))
        }

        // 2. 递归构建
        return buildRecursive(bboxes: bboxes, indices: indices)
    }

    private func buildRecursive(bboxes: [AABB], indices: [UInt32]) -> BVHNode {
        // 计算当前节点的总包围盒
        var nodeBBox = AABB()
        for i in indices {
            nodeBBox = AABB.merge(nodeBBox, bboxes[Int(i)])
        }

        // 叶节点条件
        if indices.count <= maxLeafSize {
            return BVHNode(bbox: nodeBBox, indices: indices)
        }

        // 使用 SAH 找到最佳分割
        let (axis, splitIndex) = findBestSplit(bboxes: bboxes, indices: indices, nodeBBox: nodeBBox)

        // 分割几何体
        let sortedIndices = indices.sorted { idx1, idx2 in
            let center1 = (bboxes[Int(idx1)].min + bboxes[Int(idx1)].max) / 2.0
            let center2 = (bboxes[Int(idx2)].min + bboxes[Int(idx2)].max) / 2.0
            return center1[axis] < center2[axis]
        }

        let leftIndices = Array(sortedIndices[..<splitIndex])
        let rightIndices = Array(sortedIndices[splitIndex...])

        // 递归构建左右子树
        let node = BVHNode(bbox: nodeBBox, indices: [])
        node.left = buildRecursive(bboxes: bboxes, indices: leftIndices)
        node.right = buildRecursive(bboxes: bboxes, indices: rightIndices)

        return node
    }

    /// SAH 分割（简化版：使用中位数分割）
    private func findBestSplit(bboxes: [AABB], indices: [UInt32], nodeBBox: AABB) -> (axis: Int, splitIndex: Int) {
        let axis = nodeBBox.longestAxis
        let splitIndex = indices.count / 2
        return (axis, splitIndex)
    }
}
```

**验收标准**:
- ✅ BVH 树正确构建
- ✅ 叶节点不超过 maxLeafSize
- ✅ 树深度合理（< 30 层）

---

### Task 3.3: FlatBVH 扁平化 (Day 3)

**目标**: 将 BVH 树扁平化为线性数组，方便 GPU 访问

**参考文件**:
- `~/ray_tracing/include/acceleration/flat_bvh.h`

#### 具体步骤

1. **FlatBVH 节点** - `GPU/GPUStructs.swift`

```swift
/// GPU BVH 节点（48 bytes 对齐）
struct GPUBVHNode {
    var bbox: GPUAABB           // 32 bytes
    var leftChildOrFirst: UInt32  // 4 bytes (内部节点：左子节点索引；叶节点：首个几何体索引)
    var rightChild: UInt32      // 4 bytes (内部节点：右子节点索引；叶节点：unused)
    var geometryCount: UInt32   // 4 bytes (内部节点：0；叶节点：几何体数量)
    var padding: UInt32         // 4 bytes
}  // Total: 48 bytes
```

2. **FlatBVH 构建** - `Acceleration/FlatBVH.swift`

```swift
class FlatBVH {
    var nodes: [GPUBVHNode] = []
    var geometryIndices: [UInt32] = []  // 扁平化的几何体索引

    /// 从 BVH 树扁平化
    func flatten(root: BVHNode) {
        nodes.removeAll()
        geometryIndices.removeAll()
        flattenRecursive(node: root)
    }

    private func flattenRecursive(node: BVHNode) -> UInt32 {
        let nodeIndex = UInt32(nodes.count)

        // 预留位置
        nodes.append(GPUBVHNode(
            bbox: node.bbox.toGPU(),
            leftChildOrFirst: 0,
            rightChild: 0,
            geometryCount: 0,
            padding: 0
        ))

        if node.isLeaf {
            // 叶节点：存储几何体索引
            let firstGeomIndex = UInt32(geometryIndices.count)
            geometryIndices.append(contentsOf: node.geometryIndices)

            nodes[Int(nodeIndex)].leftChildOrFirst = firstGeomIndex
            nodes[Int(nodeIndex)].geometryCount = UInt32(node.geometryIndices.count)
        } else {
            // 内部节点：递归扁平化子节点
            let leftIndex = flattenRecursive(node: node.left!)
            let rightIndex = flattenRecursive(node: node.right!)

            nodes[Int(nodeIndex)].leftChildOrFirst = leftIndex
            nodes[Int(nodeIndex)].rightChild = rightIndex
            nodes[Int(nodeIndex)].geometryCount = 0  // 0 表示内部节点
        }

        return nodeIndex
    }
}
```

**验收标准**:
- ✅ FlatBVH 节点数组正确
- ✅ 几何体索引正确存储
- ✅ 内存布局符合 GPU 要求

---

### Task 3.4: GPU BVH 遍历 (Day 4)

**目标**: 在 GPU 上实现迭代式 BVH 遍历

**参考文件**:
- `~/ray_tracing/shaders/kernels/ray_tracing_bvh.metal`

#### 具体步骤

1. **GPU 端** - `Shaders/Common/Acceleration.metal`

```metal
/// GPU BVH 节点（与 Swift 对齐）
struct GPUBVHNode {
    GPUAABB bbox;
    uint left_child_or_first;
    uint right_child;
    uint geometry_count;
    uint padding;
};

/// BVH 遍历（迭代式，固定栈）
inline bool bvh_hit(
    device const GPUBVHNode* nodes,
    device const uint* geometry_indices,
    device const GPUSphere* spheres,
    device const GPUQuad* quads,
    device const GPUTransform* transforms,
    uint sphere_count,
    Ray r,
    float t_min,
    float t_max,
    thread HitRecord* rec
) {
    const int MAX_STACK_SIZE = 32;
    uint stack[MAX_STACK_SIZE];
    int stack_ptr = 0;

    stack[stack_ptr++] = 0;  // 从根节点开始

    bool hit_anything = false;
    float closest_so_far = t_max;

    while (stack_ptr > 0) {
        uint node_idx = stack[--stack_ptr];
        GPUBVHNode node = nodes[node_idx];

        // AABB 快速拒绝
        if (!aabb_hit(node.bbox, r, t_min, closest_so_far)) {
            continue;
        }

        if (node.geometry_count > 0) {
            // 叶节点：测试所有几何体
            for (uint i = 0; i < node.geometry_count; i++) {
                uint geom_idx = geometry_indices[node.left_child_or_first + i];

                HitRecord temp_rec;
                bool hit = false;

                if (geom_idx < sphere_count) {
                    // Sphere
                    hit = sphere_hit(spheres[geom_idx], transforms, r, t_min, closest_so_far, &temp_rec);
                } else {
                    // Quad
                    uint quad_idx = geom_idx - sphere_count;
                    hit = quad_hit(quads[quad_idx], transforms, r, t_min, closest_so_far, &temp_rec);
                }

                if (hit) {
                    hit_anything = true;
                    closest_so_far = temp_rec.t;
                    *rec = temp_rec;
                }
            }
        } else {
            // 内部节点：压栈子节点
            if (stack_ptr < MAX_STACK_SIZE - 1) {
                stack[stack_ptr++] = node.left_child_or_first;
                stack[stack_ptr++] = node.right_child;
            }
        }
    }

    return hit_anything;
}
```

2. **更新渲染内核** - `Shaders/Kernels/SimpleRayTracing.metal`

```metal
// 替换原有的逐一测试，使用 BVH 加速
if (params.use_bvh != 0) {
    hit_anything = bvh_hit(
        bvh_nodes, geometry_indices,
        spheres, quads, transforms,
        params.sphere_count,
        current_ray, 0.001f, 1e10f, &rec
    );
} else {
    // 原有的逐一测试（fallback）
    // ...
}
```

**验收标准**:
- ✅ BVH 遍历正确
- ✅ 栈不溢出
- ✅ 渲染结果与无 BVH 版本一致

---

### Task 3.5: 性能测试与优化 (Day 5)

**目标**: 测试 BVH 加速效果，优化性能

#### 测试场景

1. **Final Scene** (1006球 + 2401四边形)
   - 无 BVH: 9.1 秒 @ 10 spp
   - 有 BVH: **< 500ms** @ 10 spp
   - 目标加速比: **18×**

2. **Bouncing Spheres** (488球)
   - 无 BVH: 估计 150ms @ 10 spp
   - 有 BVH: **< 15ms** @ 10 spp
   - 目标加速比: **10×**

#### 优化策略

1. **SAH 分割优化**
   - 实现完整 SAH 代价函数
   - 使用分箱（binning）加速

2. **内存布局优化**
   - BVH 节点按深度优先排序
   - 几何体数据重排序，提高缓存命中率

3. **GPU 遍历优化**
   - 优先遍历近端子节点
   - 使用 SIMD 加速 AABB 测试

**验收标准**:
- ✅ Final Scene < 500ms @ 10 spp
- ✅ Bouncing Spheres < 15ms @ 10 spp
- ✅ 加速比 > 10×

---

## 里程碑验收

**Phase 3 完成标准**:
- ✅ AABB 包围盒实现
- ✅ BVH 树构建（SAH 分割）
- ✅ FlatBVH 扁平化
- ✅ GPU BVH 遍历（迭代式）
- ✅ Final Scene 性能提升 > 10×
- ✅ Bouncing Spheres < 15ms @ 10 spp

**下一步**: Phase 4 - 多重重要性采样 (MIS)

---

## 技术要点

### 1. AABB 相交测试优化

**关键**: 使用倒数避免除法
```metal
float3 inv_dir = 1.0f / r.direction;
float3 t0 = (box.min - r.origin) * inv_dir;
float3 t1 = (box.max - r.origin) * inv_dir;
```

### 2. SAH 代价函数

**公式**:
```
Cost = C_traverse + (P_left * N_left + P_right * N_right) * C_intersect
```
- `P_left/right`: 左右子树表面积比例
- `N_left/right`: 左右子树几何体数量

### 3. GPU 迭代式遍历

**关键**: 使用固定大小栈（32层）
- 栈溢出时终止遍历（极少发生）
- 深度优先顺序，减少栈使用

### 4. 内存对齐

**规则**:
- 所有 GPU 结构体对齐到 16 字节倍数
- BVH 节点 48 bytes（32 AABB + 16 其他）

---

## 性能分析

### BVH 加速原理

**复杂度对比**:
- 无 BVH: O(N)，N = 几何体数量
- 有 BVH: O(log N)，树的深度

**加速比估算**:
- Final Scene: 3407 几何体 → log₂(3407) ≈ 11.7 → 加速 290×（理论）
- 实际加速 15-20×（考虑 AABB 测试开销）

### 内存占用

**估算**:
- BVH 节点: ~2N 个节点（二叉树）× 48 bytes
- Final Scene: 6814 节点 × 48 = 327 KB
- 几何体索引: 3407 × 4 = 13.6 KB
- **总计**: ~340 KB（可接受）

---

**文档版本**: v1.0
**创建日期**: 2025-11-27
**状态**: 📋 准备开始

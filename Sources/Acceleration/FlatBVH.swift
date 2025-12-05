import Foundation

// MARK: - 几何体包装类型（统一表示）

enum GeometryType {
    case sphere(index: Int)
    case quad(index: Int)
}

struct GeometryWrapper {
    let type: GeometryType
    let bbox: AABB

    var globalIndex: UInt32 {
        switch type {
        case .sphere(let idx):
            return UInt32(idx)
        case .quad(let idx):
            return UInt32(idx)
        }
    }
}

// MARK: - BVH 树节点（CPU 端，用于构建）

class BVHNode {
    var bbox: AABB
    var left: BVHNode?
    var right: BVHNode?
    var geometries: [GeometryWrapper]  // 叶节点存储几何体
    var axis: Int  // 分割轴

    var isLeaf: Bool {
        return left == nil && right == nil
    }

    init(bbox: AABB, geometries: [GeometryWrapper], axis: Int = 0) {
        self.bbox = bbox
        self.geometries = geometries
        self.axis = axis
        self.left = nil
        self.right = nil
    }
}

// MARK: - SAH 分箱结构

struct SAHBin {
    var count: Int = 0
    var bounds: AABB = .empty
}

// MARK: - FlatBVH 构建器

class FlatBVH {
    var nodes: [GPUBVHNode] = []
    var geometryIndices: [UInt32] = []  // 扁平化的几何体索引
    var sphereCount: Int = 0
    var quadCount: Int = 0

    private let maxLeafSize = 2  // 叶节点最大几何体数量（与 CPU 版本一致）
    private let useSAH = true  // 启用 SAH 优化（Phase 5）
    private let numBins = 16   // SAH 分箱数量

    /// 从场景构建 FlatBVH
    func build(spheres: [Sphere], quads: [Quad], transforms: [Transform], debug: Bool = false) {
        // 1. 准备几何体包装器
        var geometries: [GeometryWrapper] = []

        for (i, sphere) in spheres.enumerated() {
            let bbox = sphere.boundingBox(transforms: transforms)
            geometries.append(GeometryWrapper(type: .sphere(index: i), bbox: bbox))

            if debug {
                print("  Sphere[\(i)]: center=(\(sphere.center.x), \(sphere.center.y), \(sphere.center.z)), radius=\(sphere.radius)")
                bbox.debugPrint(prefix: "    ")
            }
        }

        for (i, quad) in quads.enumerated() {
            let bbox = quad.boundingBox(transforms: transforms)
            geometries.append(GeometryWrapper(type: .quad(index: i), bbox: bbox))

            if debug {
                print("  Quad[\(i)]:")
                bbox.debugPrint(prefix: "    ")
            }
        }

        sphereCount = spheres.count
        quadCount = quads.count

        guard !geometries.isEmpty else {
            return
        }

        // 2. 递归构建 BVH 树
        let root = buildRecursive(geometries: &geometries, start: 0, end: geometries.count, depth: 0, debug: debug)

        // 3. 扁平化为线性数组
        nodes.removeAll()
        geometryIndices.removeAll()
        nodes.reserveCapacity(geometries.count * 2)
        geometryIndices.reserveCapacity(geometries.count)

        let _ = flattenRecursive(node: root)

        if debug {
            debugPrintTree()
        }
    }

    // MARK: - SAH 最佳分割

    /// 使用 SAH (Surface Area Heuristic) 找到最佳分割位置
    /// 返回: (分割位置, 成本, 分割轴)
    private func findBestSplit(
        geometries: ArraySlice<GeometryWrapper>,
        bbox: AABB
    ) -> (split: Float, cost: Float, axis: Int)? {
        var bestCost = Float.infinity
        var bestSplit: Float = 0
        var bestAxis: Int = 0

        // 对每个轴尝试 SAH 分割
        for axis in 0..<3 {
            let (axisMin, axisMax) = bbox.axisInterval(axis)
            let extent = axisMax - axisMin

            // 退化情况：轴范围为0
            if extent < 1e-6 {
                continue
            }

            // 1. 初始化分箱
            var bins = [SAHBin](repeating: SAHBin(), count: numBins)

            // 2. 将几何体分配到分箱
            for geom in geometries {
                let centroid = geom.bbox.center[axis]
                let binIndex = min(numBins - 1, Int((centroid - axisMin) / extent * Float(numBins)))

                bins[binIndex].count += 1
                bins[binIndex].bounds = AABB.merge(bins[binIndex].bounds, geom.bbox)
            }

            // 3. 扫描计算 SAH 成本
            for i in 0..<(numBins - 1) {
                // 左侧：bins[0..i]
                var leftBox = AABB.empty
                var leftCount = 0
                for j in 0...i {
                    leftBox = AABB.merge(leftBox, bins[j].bounds)
                    leftCount += bins[j].count
                }

                // 右侧：bins[i+1..numBins-1]
                var rightBox = AABB.empty
                var rightCount = 0
                for j in (i+1)..<numBins {
                    rightBox = AABB.merge(rightBox, bins[j].bounds)
                    rightCount += bins[j].count
                }

                // 跳过空分割
                if leftCount == 0 || rightCount == 0 {
                    continue
                }

                // SAH 成本: C = t_traverse + (N_left * SA_left + N_right * SA_right) / SA_parent
                // 这里简化为: C = leftCount * leftSA + rightCount * rightSA
                let cost = Float(leftCount) * leftBox.surfaceArea +
                           Float(rightCount) * rightBox.surfaceArea

                if cost < bestCost {
                    bestCost = cost
                    bestSplit = axisMin + (Float(i + 1) / Float(numBins)) * extent
                    bestAxis = axis
                }
            }
        }

        // 如果没有找到有效分割，返回 nil
        if bestCost == Float.infinity {
            return nil
        }

        return (bestSplit, bestCost, bestAxis)
    }

    // MARK: - 递归构建 BVH 树

    private func buildRecursive(geometries: inout [GeometryWrapper], start: Int, end: Int, depth: Int = 0, debug: Bool = false) -> BVHNode {
        // 计算当前节点的总包围盒
        var nodeBBox = AABB.empty
        for i in start..<end {
            nodeBBox = AABB.merge(nodeBBox, geometries[i].bbox)
        }

        let objectSpan = end - start

        if debug {
            let indent = String(repeating: "  ", count: depth)
            print("\(indent)BuildNode[depth=\(depth), objects=\(objectSpan)]:")
            nodeBBox.debugPrint(prefix: "\(indent)  ")
        }

        // 叶节点条件：1 或 2 个几何体
        if objectSpan <= maxLeafSize {
            let leafGeometries = Array(geometries[start..<end])

            if debug {
                let indent = String(repeating: "  ", count: depth)
                print("\(indent)  -> Leaf node with \(leafGeometries.count) geometries")
                for (i, geom) in leafGeometries.enumerated() {
                    print("\(indent)    [\(i)] globalIndex=\(geom.globalIndex)")
                }
            }

            return BVHNode(bbox: nodeBBox, geometries: leafGeometries)
        }

        // 内部节点：选择分割策略
        var axis: Int
        var mid: Int

        if useSAH {
            // SAH 分割
            if let (splitPos, cost, bestAxis) = findBestSplit(
                geometries: geometries[start..<end],
                bbox: nodeBBox
            ) {
                axis = bestAxis

                if debug {
                    let indent = String(repeating: "  ", count: depth)
                    let axisName = ["X", "Y", "Z"][axis]
                    print("\(indent)  -> SAH split on axis \(axisName) at position \(splitPos) (cost: \(cost))")
                }

                // 根据 SAH 分割位置分区（手动实现，避免 partition 的复杂性）
                var leftIdx = start
                var rightIdx = end - 1

                while leftIdx <= rightIdx {
                    // 从左边找到第一个 >= splitPos 的元素
                    while leftIdx <= rightIdx && geometries[leftIdx].bbox.center[axis] < splitPos {
                        leftIdx += 1
                    }
                    // 从右边找到第一个 < splitPos 的元素
                    while leftIdx <= rightIdx && geometries[rightIdx].bbox.center[axis] >= splitPos {
                        rightIdx -= 1
                    }
                    // 交换
                    if leftIdx < rightIdx {
                        geometries.swapAt(leftIdx, rightIdx)
                        leftIdx += 1
                        rightIdx -= 1
                    }
                }

                mid = leftIdx

                // 确保分割有效（避免一边为空）
                if mid == start || mid == end {
                    // fallback 到中点分割
                    axis = nodeBBox.longestAxis
                    geometries[start..<end].sort { g1, g2 in
                        g1.bbox.center[axis] < g2.bbox.center[axis]
                    }
                    mid = start + objectSpan / 2
                }
            } else {
                // SAH 失败，fallback 到中点分割
                axis = nodeBBox.longestAxis
                geometries[start..<end].sort { g1, g2 in
                    g1.bbox.center[axis] < g2.bbox.center[axis]
                }
                mid = start + objectSpan / 2
            }
        } else {
            // 传统的中点分割
            axis = nodeBBox.longestAxis
            let axisName = ["X", "Y", "Z"][axis]

            if debug {
                let indent = String(repeating: "  ", count: depth)
                print("\(indent)  -> Split on axis \(axisName)")
            }

            geometries[start..<end].sort { g1, g2 in
                g1.bbox.center[axis] < g2.bbox.center[axis]
            }
            mid = start + objectSpan / 2
        }

        // 递归构建左右子树
        let node = BVHNode(bbox: nodeBBox, geometries: [], axis: axis)
        node.left = buildRecursive(geometries: &geometries, start: start, end: mid, depth: depth + 1, debug: debug)
        node.right = buildRecursive(geometries: &geometries, start: mid, end: end, depth: depth + 1, debug: debug)

        return node
    }

    // MARK: - 扁平化 BVH 树

    @discardableResult
    private func flattenRecursive(node: BVHNode) -> UInt32 {
        // 先创建当前节点（预留位置）
        let nodeIndex = UInt32(nodes.count)
        nodes.append(GPUBVHNode(
            bbox: node.bbox.toGPU(),
            leftChildOrFirst: 0,
            rightChild: 0,
            geometryCount: 0,
            splitAxis: UInt32(node.axis)
        ))

        if node.isLeaf {
            // 叶节点：存储几何体索引
            let firstGeomIndex = UInt32(geometryIndices.count)

            for geom in node.geometries {
                // 计算全局索引：sphere 直接用索引，quad 需要加上 sphere 数量
                var globalIndex: UInt32
                switch geom.type {
                case .sphere(let idx):
                    globalIndex = UInt32(idx)
                case .quad(let idx):
                    globalIndex = UInt32(sphereCount + idx)
                }
                geometryIndices.append(globalIndex)
            }

            // 更新叶节点信息
            nodes[Int(nodeIndex)].leftChildOrFirst = firstGeomIndex
            nodes[Int(nodeIndex)].geometryCount = UInt32(node.geometries.count)
        } else {
            // 内部节点：递归扁平化子节点
            let leftIndex = flattenRecursive(node: node.left!)
            let rightIndex = flattenRecursive(node: node.right!)

            // 更新内部节点的子节点索引
            nodes[Int(nodeIndex)].leftChildOrFirst = leftIndex
            nodes[Int(nodeIndex)].rightChild = rightIndex
        }

        return nodeIndex
    }

    // MARK: - 调试方法

    func debugPrintTree() {
        print("\n📊 FlatBVH Tree Structure:")
        print("Total nodes: \(nodes.count)")
        print("Total geometry indices: \(geometryIndices.count)")
        print()

        for (i, node) in nodes.enumerated() {
            let isLeaf = node.geometryCount > 0
            print("Node[\(i)]: \(isLeaf ? "LEAF" : "INTERNAL")")
            let min = node.bbox.minx_miny_minz_pad1
            let max = node.bbox.maxx_maxy_maxz_pad2
            print("  AABB: min=(\(min.x), \(min.y), \(min.z)), max=(\(max.x), \(max.y), \(max.z))")

            if isLeaf {
                print("  Geometries: \(node.geometryCount) starting at index \(node.leftChildOrFirst)")
                for j in 0..<node.geometryCount {
                    let geomIdx = geometryIndices[Int(node.leftChildOrFirst + j)]
                    let geomType = geomIdx < sphereCount ? "Sphere" : "Quad"
                    print("    [\(j)] global index=\(geomIdx) (\(geomType))")
                }
            } else {
                print("  Children: left=\(node.leftChildOrFirst), right=\(node.rightChild)")
            }
            print()
        }
    }
}

import simd

/// Axis-Aligned Bounding Box (轴对齐包围盒)
struct AABB {
    var min: Point3
    var max: Point3

    // MARK: - 初始化

    init() {
        self.min = Point3(Float.infinity, Float.infinity, Float.infinity)
        self.max = Point3(-Float.infinity, -Float.infinity, -Float.infinity)
    }

    init(min: Point3, max: Point3) {
        self.min = min
        self.max = max
    }

    /// 从两个点构建包围盒（自动排序）
    init(a: Point3, b: Point3) {
        self.min = simd_min(a, b)
        self.max = simd_max(a, b)
    }

    /// 从两个包围盒合并
    init(_ box0: AABB, _ box1: AABB) {
        self.min = simd_min(box0.min, box1.min)
        self.max = simd_max(box0.max, box1.max)
    }

    // MARK: - 静态常量

    static let empty = AABB(
        min: Point3(Float.infinity, Float.infinity, Float.infinity),
        max: Point3(-Float.infinity, -Float.infinity, -Float.infinity)
    )

    static let universe = AABB(
        min: Point3(-Float.infinity, -Float.infinity, -Float.infinity),
        max: Point3(Float.infinity, Float.infinity, Float.infinity)
    )

    // MARK: - 包围盒操作

    /// 合并两个包围盒
    static func merge(_ box1: AABB, _ box2: AABB) -> AABB {
        return AABB(
            min: simd_min(box1.min, box2.min),
            max: simd_max(box1.max, box2.max)
        )
    }

    /// 扩展包围盒以包含一个点
    mutating func expand(by point: Point3) {
        self.min = simd_min(self.min, point)
        self.max = simd_max(self.max, point)
    }

    /// 扩展包围盒（避免退化到平面）
    func pad() -> AABB {
        let delta: Float = 0.0001
        let size = max - min

        var newMin = min
        var newMax = max

        if size.x < delta {
            newMin.x -= delta * 0.5
            newMax.x += delta * 0.5
        }
        if size.y < delta {
            newMin.y -= delta * 0.5
            newMax.y += delta * 0.5
        }
        if size.z < delta {
            newMin.z -= delta * 0.5
            newMax.z += delta * 0.5
        }

        return AABB(min: newMin, max: newMax)
    }

    /// 包围盒表面积（用于 SAH）
    var surfaceArea: Float {
        let d = max - min
        return 2.0 * (d.x * d.y + d.y * d.z + d.z * d.x)
    }

    /// 包围盒体积
    var volume: Float {
        let d = max - min
        return d.x * d.y * d.z
    }

    /// 最长轴索引 (0=X, 1=Y, 2=Z)
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

    /// 中心点
    var center: Point3 {
        return (min + max) * 0.5
    }

    /// 获取指定轴的区间
    func axisInterval(_ axis: Int) -> (min: Float, max: Float) {
        switch axis {
        case 0: return (min.x, max.x)
        case 1: return (min.y, max.y)
        case 2: return (min.z, max.z)
        default: return (min.x, max.x)
        }
    }

    // MARK: - 转换为 GPU 数据

    func toGPU() -> GPUAABB {
        return GPUAABB(min: min, max: max)
    }

    // MARK: - 调试输出

    func debugPrint(prefix: String = "") {
        print("\(prefix)AABB: min=(\(min.x), \(min.y), \(min.z)), max=(\(max.x), \(max.y), \(max.z))")
        let size = max - min
        print("\(prefix)  Size: (\(size.x), \(size.y), \(size.z))")
        print("\(prefix)  Center: (\(center.x), \(center.y), \(center.z))")
        print("\(prefix)  Surface Area: \(surfaceArea)")
    }
}

// MARK: - 变换辅助函数

/// 应用旋转到点（Swift端实现，与GPU端对应）
fileprivate func applyRotation(_ transform: Transform, _ point: Point3) -> Point3 {
    // 将角度转换为弧度
    let pitch = transform.rotation.x * Float.pi / 180.0
    let yaw = transform.rotation.y * Float.pi / 180.0
    let roll = transform.rotation.z * Float.pi / 180.0

    // 计算旋转矩阵（与Transform.toGPU()相同）
    let cosPitch = cos(pitch)
    let sinPitch = sin(pitch)
    let cosYaw = cos(yaw)
    let sinYaw = sin(yaw)
    let cosRoll = cos(roll)
    let sinRoll = sin(roll)

    // 旋转矩阵 R = Rz(roll) * Ry(yaw) * Rx(pitch)
    let m00 = cosYaw * cosRoll
    let m01 = cosYaw * sinRoll
    let m02 = sinYaw

    let m10 = sinPitch * sinYaw * cosRoll - cosPitch * sinRoll
    let m11 = sinPitch * sinYaw * sinRoll + cosPitch * cosRoll
    let m12 = -sinPitch * cosYaw

    let m20 = -cosPitch * sinYaw * cosRoll - sinPitch * sinRoll
    let m21 = -cosPitch * sinYaw * sinRoll + sinPitch * cosRoll
    let m22 = cosPitch * cosYaw

    // 应用旋转矩阵
    return Point3(
        m00 * point.x + m01 * point.y + m02 * point.z,
        m10 * point.x + m11 * point.y + m12 * point.z,
        m20 * point.x + m21 * point.y + m22 * point.z
    )
}

// MARK: - 几何体包围盒扩展

extension Sphere {
    /// 计算包围盒（不考虑变换）
    func boundingBox() -> AABB {
        let r = SIMD3<Float>(radius, radius, radius)
        return AABB(min: center - r, max: center + r)
    }

    /// 计算包围盒（考虑变换）
    func boundingBox(transforms: [Transform]) -> AABB {
        // 如果没有变换，使用简单的球体AABB
        if transformIndex < 0 || transformIndex >= transforms.count {
            return boundingBox()
        }

        let transform = transforms[Int(transformIndex)]

        // 对于球体，旋转不改变半径，只改变球心位置
        // 因此AABB始终是以变换后的球心为中心、半径为R的立方体
        let rotatedCenter = applyRotation(transform, center)
        let worldCenter = rotatedCenter + transform.translation
        let r = SIMD3<Float>(radius, radius, radius)
        return AABB(min: worldCenter - r, max: worldCenter + r)
    }
}

extension Quad {
    /// 计算包围盒（考虑变换）
    func boundingBox(transforms: [Transform]) -> AABB {
        // Quad 的 4 个角点（物体空间）
        var corners = [
            corner,
            corner + sideA,
            corner + sideB,
            corner + sideA + sideB
        ]

        // 如果有变换，将角点变换到世界空间
        if transformIndex >= 0 && transformIndex < transforms.count {
            let transform = transforms[Int(transformIndex)]
            corners = corners.map { point in
                let rotated = applyRotation(transform, point)
                return rotated + transform.translation
            }
        }

        // 用变换后的角点计算AABB
        var box = AABB()
        for c in corners {
            box.expand(by: c)
        }

        // 扩展一点点避免退化
        return box.pad()
    }
}

// MARK: - 平移操作

extension AABB {
    static func + (bbox: AABB, offset: Vec3) -> AABB {
        return AABB(min: bbox.min + offset, max: bbox.max + offset)
    }

    static func + (offset: Vec3, bbox: AABB) -> AABB {
        return bbox + offset
    }
}

// Ray.swift
// 光线定义

import simd

struct Ray {
    var origin: Point3
    var direction: Vec3
    var time: Float

    init(origin: Point3, direction: Vec3, time: Float = 0.0) {
        self.origin = origin
        self.direction = direction
        self.time = time
    }

    /// 计算光线在参数 t 处的位置
    func at(_ t: Float) -> Point3 {
        return origin + t * direction
    }
}

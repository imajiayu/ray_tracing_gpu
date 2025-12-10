// Geometry.metal
// 几何体相交测试 (GPU)

#ifndef GEOMETRY_METAL
#define GEOMETRY_METAL

#include <metal_stdlib>
#include "Types.metal"
#include "Transform.metal"
using namespace metal;

// ========== 命中记录 ==========

struct HitRecord {
    float3 p;               // 交点位置
    float3 normal;          // 法线
    float t;                // 光线参数
    bool front_face;        // 是否正面
    uint material_index;    // 材质索引
    float u;                // UV 坐标 u (0-1)
    float v;                // UV 坐标 v (0-1)
};

/// 设置法线方向（保证法线始终指向光线来源侧）
inline void set_face_normal(thread HitRecord* rec, Ray r, float3 outward_normal) {
    rec->front_face = dot(r.direction, outward_normal) < 0.0f;
    rec->normal = rec->front_face ? outward_normal : -outward_normal;
}

// ========== 球体相交测试 ==========

/// 计算球体UV坐标
/// p: 单位球面上的点（从球心指向交点的归一化向量）
/// 参考 ~/ray_tracing/include/geometry/sphere.h get_sphere_uv
inline void get_sphere_uv(float3 p, thread float* u, thread float* v) {
    // theta: 从 -Y 轴的角度 [0, pi]
    // phi: 从 -Z 轴绕 Y 轴的角度 [0, 2*pi]
    float theta = acos(-p.y);
    float phi = atan2(-p.z, p.x) + M_PI_F;

    *u = phi / (2.0f * M_PI_F);
    *v = theta / M_PI_F;
}

/// 光线-球体相交测试（支持变换）
/// 参考 ~/ray_tracing/include/geometry/sphere.h
inline bool sphere_hit(
    GPUSphere sphere,
    device const GPUTransform* transforms,
    Ray r,
    float t_min,
    float t_max,
    thread HitRecord* rec
) {
    Ray test_ray = r;

    // 如果有变换，将光线变换到物体空间
    if (sphere.transform_index >= 0) {
        GPUTransform t = transforms[sphere.transform_index];
        test_ray = transform_ray_to_object_space(t, r);
    }

    float3 oc = test_ray.origin - sphere.center;

    // 二次方程系数
    float a = dot(test_ray.direction, test_ray.direction);
    float half_b = dot(oc, test_ray.direction);
    float c = dot(oc, oc) - sphere.radius * sphere.radius;

    // 判别式
    float discriminant = half_b * half_b - a * c;
    if (discriminant < 0.0f) {
        return false;
    }

    float sqrtd = sqrt(discriminant);

    // 找最近的根（在有效范围内）
    float root = (-half_b - sqrtd) / a;
    if (root < t_min || t_max < root) {
        root = (-half_b + sqrtd) / a;
        if (root < t_min || t_max < root) {
            return false;
        }
    }

    // 记录命中信息（在物体空间）
    rec->t = root;
    float3 local_p = ray_at(test_ray, rec->t);
    rec->material_index = sphere.material_index;

    // 计算法线（在物体空间，从球心指向交点）
    float3 local_normal = (local_p - sphere.center) / sphere.radius;

    // 计算UV坐标（基于归一化的法线向量）
    get_sphere_uv(local_normal, &rec->u, &rec->v);

    // 如果有变换，将交点和法线变换回世界空间
    if (sphere.transform_index >= 0) {
        GPUTransform t = transforms[sphere.transform_index];
        rec->p = transform_point_to_world_space(t, local_p);
        float3 world_normal = transform_normal_to_world_space(t, local_normal);
        set_face_normal(rec, r, normalize(world_normal));
    } else {
        rec->p = local_p;
        set_face_normal(rec, r, local_normal);
    }

    return true;
}

// ========== Constant Medium 体积雾相交测试 ==========

/// 光线-体积雾球体相交测试
/// 参考 ~/ray_tracing/include/geometry/constant_medium.h
inline bool sphere_hit_constant_medium(
    GPUSphere sphere,
    device const GPUTransform* transforms,
    Ray r,
    float t_min,
    float t_max,
    thread HitRecord* rec,
    thread RandomState* rng
) {
    // 检查是否为体积雾（neg_inv_density != 0）
    if (sphere.neg_inv_density == 0.0f) {
        return sphere_hit(sphere, transforms, r, t_min, t_max, rec);
    }

    // CPU版本的关键优化：AABB预检查（constant_medium.h:22-25）
    // 如果光线在[t_min, t_max]范围内不击中AABB，直接返回
    // 这避免了BVH遍历顺序导致的不一致
    {
        float3 box_min = sphere.center - sphere.radius;
        float3 box_max = sphere.center + sphere.radius;
        float3 inv_dir = 1.0f / r.direction;
        float3 t0 = (box_min - r.origin) * inv_dir;
        float3 t1 = (box_max - r.origin) * inv_dir;
        float3 tmin = min(t0, t1);
        float3 tmax = max(t0, t1);
        float t_enter = max(max(tmin.x, tmin.y), max(tmin.z, t_min));
        float t_exit = min(min(tmax.x, tmax.y), min(tmax.z, t_max));

        if (t_enter > t_exit) {
            return false; // AABB不相交，快速拒绝
        }
    }

    // 找到光线进入和离开边界的两个交点
    HitRecord rec1, rec2;

    // 第一次相交
    if (!sphere_hit(sphere, transforms, r, -1e10f, 1e10f, &rec1)) {
        return false;
    }

    // 第二次相交
    bool has_second_hit = sphere_hit(sphere, transforms, r, rec1.t + 0.001f, 1e10f, &rec2);

    if (!has_second_hit) {
        // 只找到一个交点：光线起点在球内
        rec2 = rec1;
        rec1.t = 0.0f;
    }

    // 裁剪到有效范围（入口）
    if (rec1.t < 0.0f) rec1.t = 0.0f;
    if (rec1.t < t_min) rec1.t = t_min;

    // ⚠️ 关键修复：不裁剪rec2.t到t_max！
    // 体积雾的散射概率应该只取决于完整的体积段，不受其他物体影响
    // 我们在后面判断散射点是否比t_max更近

    if (rec1.t >= rec2.t) {
        return false;
    }

    // 计算光线在边界内的距离
    float ray_length = length(r.direction);
    float distance_inside_boundary = (rec2.t - rec1.t) * ray_length;

    // 概率性光线行进
    float hit_distance = sphere.neg_inv_density * log(random_float(rng));

    if (hit_distance > distance_inside_boundary) {
        return false;
    }

    // 计算散射点
    float scatter_t = rec1.t + hit_distance / ray_length;

    // 如果散射点比已知的最近物体更远，拒绝散射
    if (scatter_t > t_max) {
        return false;
    }

    // 记录散射点
    rec->t = scatter_t;
    rec->p = ray_at(r, rec->t);
    rec->normal = float3(1, 0, 0);
    rec->front_face = true;
    rec->material_index = sphere.isotropic_mat_index;
    rec->u = 0.0f;
    rec->v = 0.0f;

    return true;
}

// ========== Quad 相交测试 ==========

/// 光线-Quad(矩形)相交测试（支持变换）
/// 参考 ~/ray_tracing/include/geometry/quad.h
inline bool quad_hit(
    GPUQuad quad,
    device const GPUTransform* transforms,
    Ray r,
    float t_min,
    float t_max,
    thread HitRecord* rec
) {
    Ray test_ray = r;

    // 如果有变换，将光线变换到物体空间
    if (quad.transform_index >= 0) {
        GPUTransform t = transforms[quad.transform_index];
        test_ray = transform_ray_to_object_space(t, r);
    }

    float denom = dot(quad.normal, test_ray.direction);

    // 光线平行于平面，无交点
    if (abs(denom) < 1e-8f) {
        return false;
    }

    // 计算交点参数 t
    float t = (-quad.D - dot(quad.normal, test_ray.origin)) / denom;
    if (t < t_min || t > t_max) {
        return false;
    }

    // 计算交点位置（在物体空间）
    float3 local_intersection = ray_at(test_ray, t);

    // 计算平面坐标 (a, b)
    float3 planar_hitpt_vector = local_intersection - quad.corner;
    float a = dot(quad.w, cross(planar_hitpt_vector, quad.side_B));
    float b = dot(quad.w, cross(quad.side_A, planar_hitpt_vector));

    // 检查是否在矩形内 [0, 1] × [0, 1]
    if ((a < 0.0f) || (1.0f < a) || (b < 0.0f) || (1.0f < b)) {
        return false;
    }

    // 记录命中信息
    rec->t = t;
    rec->material_index = quad.material_index;

    // 设置UV坐标（a, b就是归一化的平面坐标，对应UV）
    rec->u = a;
    rec->v = b;

    // 如果有变换，将交点和法线变换回世界空间
    if (quad.transform_index >= 0) {
        GPUTransform t = transforms[quad.transform_index];
        rec->p = transform_point_to_world_space(t, local_intersection);
        float3 world_normal = transform_normal_to_world_space(t, quad.normal);
        set_face_normal(rec, r, normalize(world_normal));
    } else {
        rec->p = local_intersection;
        set_face_normal(rec, r, quad.normal);
    }

    return true;
}

#endif // GEOMETRY_METAL

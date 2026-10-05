// Minimal vector/quaternion math for the KF2-VR core.
//
// Deliberately small and dependency-free: this code sits under golden tests and
// is the substrate for every pose the project produces. Anything exotic belongs
// in the engine adapter, not here.
#pragma once

#include <cmath>

namespace kf2vr {

struct Vec3 {
    float x = 0.f, y = 0.f, z = 0.f;

    constexpr Vec3() = default;
    constexpr Vec3(float x_, float y_, float z_) : x(x_), y(y_), z(z_) {}

    constexpr Vec3 operator+(const Vec3& o) const { return {x + o.x, y + o.y, z + o.z}; }
    constexpr Vec3 operator-(const Vec3& o) const { return {x - o.x, y - o.y, z - o.z}; }
    constexpr Vec3 operator-() const { return {-x, -y, -z}; }
    constexpr Vec3 operator*(float s) const { return {x * s, y * s, z * s}; }

    constexpr float Dot(const Vec3& o) const { return x * o.x + y * o.y + z * o.z; }
    constexpr Vec3  Cross(const Vec3& o) const {
        return {y * o.z - z * o.y, z * o.x - x * o.z, x * o.y - y * o.x};
    }
    float LengthSq() const { return Dot(*this); }
    float Length() const { return std::sqrt(LengthSq()); }
    Vec3  Normalized() const {
        const float l = Length();
        return l > 0.f ? *this * (1.f / l) : Vec3{};
    }
};

// Unit quaternion. Stored (x, y, z, w); w is the scalar part.
struct Quat {
    float x = 0.f, y = 0.f, z = 0.f, w = 1.f;

    constexpr Quat() = default;
    constexpr Quat(float x_, float y_, float z_, float w_) : x(x_), y(y_), z(z_), w(w_) {}

    static Quat Identity() { return {}; }

    // Right-handed rotation of `radians` about `axis` (axis need not be unit).
    static Quat FromAxisAngle(const Vec3& axis, float radians) {
        const Vec3  a = axis.Normalized();
        const float h = radians * 0.5f;
        const float s = std::sin(h);
        return {a.x * s, a.y * s, a.z * s, std::cos(h)};
    }

    // Composition: (a * b) applies b first, then a — matrix convention.
    constexpr Quat operator*(const Quat& o) const {
        return {w * o.x + x * o.w + y * o.z - z * o.y,
                w * o.y - x * o.z + y * o.w + z * o.x,
                w * o.z + x * o.y - y * o.x + z * o.w,
                w * o.w - x * o.x - y * o.y - z * o.z};
    }

    constexpr Quat Conjugate() const { return {-x, -y, -z, w}; }

    // Unit quaternions only: the conjugate is the inverse.
    constexpr Quat Inverse() const { return Conjugate(); }

    float LengthSq() const { return x * x + y * y + z * z + w * w; }

    Quat Normalized() const {
        const float l = std::sqrt(LengthSq());
        if (l <= 0.f) return Identity();
        const float k = 1.f / l;
        return {x * k, y * k, z * k, w * k};
    }

    Vec3 Rotate(const Vec3& v) const {
        // v + 2w(q x v) + 2(q x (q x v)), with q the vector part.
        const Vec3 q{x, y, z};
        const Vec3 t = q.Cross(v) * 2.f;
        return v + t * w + q.Cross(t);
    }
};

// 3x3 column-major-ish helper used only by the basis conversion, which involves
// a handedness flip and therefore cannot be expressed as a quaternion product.
struct Mat3 {
    // m[row][col]
    float m[3][3] = {{1, 0, 0}, {0, 1, 0}, {0, 0, 1}};

    static Mat3 FromQuat(const Quat& q) {
        const float xx = q.x * q.x, yy = q.y * q.y, zz = q.z * q.z;
        const float xy = q.x * q.y, xz = q.x * q.z, yz = q.y * q.z;
        const float wx = q.w * q.x, wy = q.w * q.y, wz = q.w * q.z;
        Mat3 r;
        r.m[0][0] = 1 - 2 * (yy + zz); r.m[0][1] = 2 * (xy - wz);     r.m[0][2] = 2 * (xz + wy);
        r.m[1][0] = 2 * (xy + wz);     r.m[1][1] = 1 - 2 * (xx + zz); r.m[1][2] = 2 * (yz - wx);
        r.m[2][0] = 2 * (xz - wy);     r.m[2][1] = 2 * (yz + wx);     r.m[2][2] = 1 - 2 * (xx + yy);
        return r;
    }

    Vec3 operator*(const Vec3& v) const {
        return {m[0][0] * v.x + m[0][1] * v.y + m[0][2] * v.z,
                m[1][0] * v.x + m[1][1] * v.y + m[1][2] * v.z,
                m[2][0] * v.x + m[2][1] * v.y + m[2][2] * v.z};
    }

    Mat3 operator*(const Mat3& o) const {
        Mat3 r;
        for (int i = 0; i < 3; ++i)
            for (int j = 0; j < 3; ++j)
                r.m[i][j] = m[i][0] * o.m[0][j] + m[i][1] * o.m[1][j] + m[i][2] * o.m[2][j];
        return r;
    }

    // Shepperd's method: numerically stable for any rotation matrix.
    Quat ToQuat() const {
        const float tr = m[0][0] + m[1][1] + m[2][2];
        Quat q;
        if (tr > 0.f) {
            const float s = std::sqrt(tr + 1.f) * 2.f;
            q.w = 0.25f * s;
            q.x = (m[2][1] - m[1][2]) / s;
            q.y = (m[0][2] - m[2][0]) / s;
            q.z = (m[1][0] - m[0][1]) / s;
        } else if (m[0][0] > m[1][1] && m[0][0] > m[2][2]) {
            const float s = std::sqrt(1.f + m[0][0] - m[1][1] - m[2][2]) * 2.f;
            q.w = (m[2][1] - m[1][2]) / s;
            q.x = 0.25f * s;
            q.y = (m[0][1] + m[1][0]) / s;
            q.z = (m[0][2] + m[2][0]) / s;
        } else if (m[1][1] > m[2][2]) {
            const float s = std::sqrt(1.f + m[1][1] - m[0][0] - m[2][2]) * 2.f;
            q.w = (m[0][2] - m[2][0]) / s;
            q.x = (m[0][1] + m[1][0]) / s;
            q.y = 0.25f * s;
            q.z = (m[1][2] + m[2][1]) / s;
        } else {
            const float s = std::sqrt(1.f + m[2][2] - m[0][0] - m[1][1]) * 2.f;
            q.w = (m[1][0] - m[0][1]) / s;
            q.x = (m[0][2] + m[2][0]) / s;
            q.y = (m[1][2] + m[2][1]) / s;
            q.z = 0.25f * s;
        }
        return q.Normalized();
    }
};

}  // namespace kf2vr

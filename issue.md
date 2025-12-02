1. 体积雾
2. 抗锯齿
3. 多重重要性采样
4. Shadow Acne
Fixing Shadow Acne
There’s also a subtle bug that we need to address. A ray will attempt to accurately calculate the intersection point when it intersects with a surface. Unfortunately for us, this calculation is susceptible to floating point rounding errors which can cause the intersection point to be ever so slightly off. This means that the origin of the next ray, the ray that is randomly scattered off of the surface, is unlikely to be perfectly flush with the surface. It might be just above the surface. It might be just below the surface. If the ray's origin is just below the surface then it could intersect with that surface again. Which means that it will find the nearest surface at 𝑡=0.00000001
 or whatever floating point approximation the hit function gives us. The simplest hack to address this is just to ignore hits that are very close to the calculated intersection point:

class camera {
  ...
  private:
    ...
    color ray_color(const ray& r, int depth, const hittable& world) const {
        // If we've exceeded the ray bounce limit, no more light is gathered.
        if (depth <= 0)
            return color(0,0,0);

        hit_record rec;

        if (world.hit(r, interval(0.001, infinity), rec)) {
            vec3 direction = random_on_hemisphere(rec.normal);
            return 0.5 * ray_color(ray(rec.p, direction), depth-1, world);
        }

        vec3 unit_direction = unit_vector(r.direction());
        auto a = 0.5*(unit_direction.y() + 1.0);
        return (1.0-a)*color(1.0, 1.0, 1.0) + a*color(0.5, 0.7, 1.0);
    }
};
5. 伽马矫正
6. Surface Acne
An astute reader pointed out there are some black specks in the image above. All Monte Carlo Ray Tracers have this as a main loop:

pixel_color = average(many many samples)
If you find yourself getting some form of acne in your renders, and this acne is white or black — where one “bad” sample seems to kill the whole pixel — then that sample is probably a huge number or a NaN (Not A Number). This particular acne is probably a NaN. Mine seems to come up once in every 10–100 million rays or so.

So big decision: sweep this bug under the rug and check for NaNs, or just kill NaNs and hope this doesn't come back to bite us later. I will always opt for the lazy strategy, especially when I know that working with floating point is hard. First, how do we check for a NaN? The one thing I always remember for NaNs is that a NaN does not equal itself. Using this trick, we update the write_color() function to replace any NaN components with zero:
void write_color(std::ostream& out, const color& pixel_color) {
    auto r = pixel_color.x();
    auto g = pixel_color.y();
    auto b = pixel_color.z();

    // Replace NaN components with zero.
    if (r != r) r = 0.0;
    if (g != g) g = 0.0;
    if (b != b) b = 0.0;

    // Apply a linear to gamma transform for gamma 2
    r = linear_to_gamma(r);
    g = linear_to_gamma(g);
    b = linear_to_gamma(b);

    // Translate the [0,1] component values to the byte range [0,255].
    static const interval intensity(0.000, 0.999);
    int rbyte = int(256 * intensity.clamp(r));
    int gbyte = int(256 * intensity.clamp(g));
    int bbyte = int(256 * intensity.clamp(b));

    // Write out the pixel color components.
    out << rbyte << ' ' << gbyte << ' ' << bbyte << '\n';
}
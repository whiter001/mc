module main

// Port of crates/edit/src/oklab.rs (microsoft/edit).
// Oklab colorspace conversions. StraightRgba and Oklab types,
// plus the sRGB <-> linear LUT and the fast cube-root estimator.
//
// Reference: https://bottosson.github.io/posts/oklab/

import math

// StraightRgba is an sRGB color with straight (= not premultiplied) alpha.
// In Rust it's `#[repr(transparent)] struct StraightRgba(u32)`.
struct StraightRgba {
	value u32
}

fn straight_rgba_from_rgba(color u32) StraightRgba {
	return StraightRgba{ value: color }
}

fn (c StraightRgba) to_rgba() u32 {
	return c.value
}

fn (c StraightRgba) red() u32 {
	return c.value >> 24
}

fn (c StraightRgba) green() u32 {
	return (c.value >> 16) & 0xff
}

fn (c StraightRgba) blue() u32 {
	return (c.value >> 8) & 0xff
}

fn (c StraightRgba) alpha() u32 {
	return c.value & 0xff
}

// oklab_blend blends `top` over `self` (bottom) in the Oklab colorspace.
fn (bottom StraightRgba) oklab_blend(top StraightRgba) StraightRgba {
	bottom_lab := bottom.as_oklab()
	top_lab := top.as_oklab()
	res := bottom_lab.blend(top_lab)
	return res.as_rgba()
}

// as_oklab converts the sRGB color to Oklab (with straight alpha).
fn (c StraightRgba) as_oklab() Oklab {
	r := srgb_to_linear(c.red())
	g := srgb_to_linear(c.green())
	b := srgb_to_linear(c.blue())
	alpha := f32(c.alpha()) * (f32(1.0) / f32(255.0))

	l := f32(0.4122214708) * r + f32(0.5363325363) * g + f32(0.0514459929) * b
	m := f32(0.2119034982) * r + f32(0.6806995451) * g + f32(0.1073969566) * b
	s := f32(0.0883024619) * r + f32(0.2817188376) * g + f32(0.6299787005) * b

	l_ := cbrtf_est(l)
	m_ := cbrtf_est(m)
	s_ := cbrtf_est(s)

	ll := f32(0.2104542553) * l_ + f32(0.7936177850) * m_ - f32(0.0040720468) * s_
	a := f32(1.9779984951) * l_ - f32(2.4285922050) * m_ + f32(0.4505937099) * s_
	bb := f32(0.0259040371) * l_ + f32(0.7827717662) * m_ - f32(0.8086757660) * s_

	return Oklab{ data: [f32(ll), f32(a), f32(bb), alpha]! }
}

// Oklab is an Oklab color with alpha. By convention, it uses straight alpha.
struct Oklab {
	data [4]f32
}

fn (c Oklab) lightness() f32 {
	return c.data[0]
}

fn (c Oklab) a() f32 {
	return c.data[1]
}

fn (c Oklab) b() f32 {
	return c.data[2]
}

fn (c Oklab) alpha() f32 {
	return c.data[3]
}

// as_rgba converts the Oklab color back to a packed StraightRgba (0xRRGGBBAA).
fn (c &Oklab) as_rgba() StraightRgba {
	l_ := c.lightness() + f32(0.3963377774) * c.a() + f32(0.2158037573) * c.b()
	m_ := c.lightness() - f32(0.1055613458) * c.a() - f32(0.0638541728) * c.b()
	s_ := c.lightness() - f32(0.0894841775) * c.a() - f32(1.2914855480) * c.b()

	l := l_ * l_ * l_
	m := m_ * m_ * m_
	s := s_ * s_ * s_

	mut r := f32(4.0767416621) * l - f32(3.3077115913) * m + f32(0.2309699292) * s
	mut g := f32(-1.2684380046) * l + f32(2.6097574011) * m - f32(0.3413193965) * s
	bb := f32(-0.0041960863) * l - f32(0.7034186147) * m + f32(1.7076147010) * s

	r = clampf(r, f32(0.0), f32(1.0))
	g = clampf(g, f32(0.0), f32(1.0))
	b := clampf(bb, f32(0.0), f32(1.0))
	alpha := clampf(c.alpha(), f32(0.0), f32(1.0))

	rl := linear_to_srgb(r)
	gl := linear_to_srgb(g)
	bl := linear_to_srgb(b)
	a := u32(alpha * f32(255.0))

	return StraightRgba{ value: (rl << 24) | (gl << 16) | (bl << 8) | a }
}

// blend performs a Porter-Duff "over" composition in Lab space.
fn (c &Oklab) blend(top Oklab) Oklab {
	top_a := top.alpha()
	bottom_a := c.alpha() * (f32(1.0) - top_a)

	mut l := top.lightness() * top_a + c.lightness() * bottom_a
	mut a := top.a() * top_a + c.a() * bottom_a
	mut bb := top.b() * top_a + c.b() * bottom_a
	alpha := top_a + bottom_a

	mut inv_alpha := f32(0.0)
	if alpha > f32(0.0) {
		inv_alpha = f32(1.0) / alpha
	}

	l = l * inv_alpha
	a = a * inv_alpha
	bb = bb * inv_alpha

	return Oklab{ data: [f32(l), f32(a), f32(bb), alpha]! }
}

fn clampf(v f32, lo f32, hi f32) f32 {
	if v < lo {
		return lo
	}
	if v > hi {
		return hi
	}
	return v
}

fn srgb_to_linear(c u32) f32 {
	return srgb_to_rgb_lut[int(c & 0xff)]
}

fn linear_to_srgb(c f32) u32 {
	mut v := f32(0.0)
	if c > f32(0.0031308) {
		v = f32(255.0) * f32(1.055) * f32(math.pow(f64(c), f64(1.0) / f64(2.4))) - f32(255.0) * f32(0.055)
	} else {
		v = f32(255.0) * f32(12.92) * c
	}
	return u32(v)
}

// cbrtf_est is a fast cube-root estimator using bit-level hacking plus one
// Newton iteration, identical to the Rust reference. Good enough for colors.
fn cbrtf_est(a f32) f32 {
	mut u := f32_bits(a)
	u = u / 3 + 709921077
	x := bits_f32(u)
	inv3 := f32(1.0) / f32(3.0)
	return inv3 * (a / (x * x) + (x + x))
}

// f32_bits reinterprets the bits of an f32 as a u32 (evil floating point bit hack).
fn f32_bits(f f32) u32 {
	mut u := u32(0)
	unsafe {
		p := voidptr(&f)
		u = *(&u32(p))
	}
	return u
}

// bits_f32 reinterprets the bits of a u32 as an f32.
fn bits_f32(b u32) f32 {
	mut f := f32(0)
	unsafe {
		p := voidptr(&b)
		f = *(&f32(p))
	}
	return f
}

// srgb_to_rgb_lut is the sRGB -> linear RGB lookup table (256 entries).
// Ported verbatim from crates/edit/src/oklab.rs SRGB_TO_RGB_LUT.

const srgb_to_rgb_lut = [
    f32(0.0000000000), f32(0.0003035270), f32(0.0006070540), f32(0.0009105810), f32(0.0012141080), f32(0.0015176350), f32(0.0018211619), f32(0.0021246888),
    f32(0.0024282159), f32(0.0027317430), f32(0.0030352699), f32(0.0033465356), f32(0.0036765069), f32(0.0040247170), f32(0.0043914421), f32(0.0047769533),
    f32(0.0051815170), f32(0.0056053917), f32(0.0060488326), f32(0.0065120910), f32(0.0069954102), f32(0.0074990317), f32(0.0080231922), f32(0.0085681248),
    f32(0.0091340570), f32(0.0097212177), f32(0.0103298230), f32(0.0109600937), f32(0.0116122449), f32(0.0122864870), f32(0.0129830306), f32(0.0137020806),
    f32(0.0144438436), f32(0.0152085144), f32(0.0159962922), f32(0.0168073755), f32(0.0176419523), f32(0.0185002182), f32(0.0193823613), f32(0.0202885624),
    f32(0.0212190095), f32(0.0221738834), f32(0.0231533647), f32(0.0241576303), f32(0.0251868572), f32(0.0262412224), f32(0.0273208916), f32(0.0284260381),
    f32(0.0295568332), f32(0.0307134409), f32(0.0318960287), f32(0.0331047624), f32(0.0343398079), f32(0.0356013142), f32(0.0368894450), f32(0.0382043645),
    f32(0.0395462364), f32(0.0409151986), f32(0.0423114114), f32(0.0437350273), f32(0.0451862030), f32(0.0466650836), f32(0.0481718220), f32(0.0497065634),
    f32(0.0512694679), f32(0.0528606549), f32(0.0544802807), f32(0.0561284944), f32(0.0578054339), f32(0.0595112406), f32(0.0612460710), f32(0.0630100295),
    f32(0.0648032799), f32(0.0666259527), f32(0.0684781820), f32(0.0703601092), f32(0.0722718611), f32(0.0742135793), f32(0.0761853904), f32(0.0781874284),
    f32(0.0802198276), f32(0.0822827145), f32(0.0843762159), f32(0.0865004659), f32(0.0886556059), f32(0.0908417329), f32(0.0930589810), f32(0.0953074843),
    f32(0.0975873619), f32(0.0998987406), f32(0.1022417471), f32(0.1046164930), f32(0.1070231125), f32(0.1094617173), f32(0.1119324341), f32(0.1144353822),
    f32(0.1169706732), f32(0.1195384338), f32(0.1221387982), f32(0.1247718409), f32(0.1274376959), f32(0.1301364899), f32(0.1328683347), f32(0.1356333494),
    f32(0.1384316236), f32(0.1412633061), f32(0.1441284865), f32(0.1470272839), f32(0.1499598026), f32(0.1529261619), f32(0.1559264660), f32(0.1589608639),
    f32(0.1620294005), f32(0.1651322246), f32(0.1682693958), f32(0.1714410931), f32(0.1746473908), f32(0.1778884083), f32(0.1811642349), f32(0.1844749898),
    f32(0.1878207624), f32(0.1912016720), f32(0.1946178079), f32(0.1980693042), f32(0.2015562356), f32(0.2050787061), f32(0.2086368501), f32(0.2122307271),
    f32(0.2158605307), f32(0.2195262313), f32(0.2232279778), f32(0.2269658893), f32(0.2307400703), f32(0.2345506549), f32(0.2383976579), f32(0.2422811985),
    f32(0.2462013960), f32(0.2501583695), f32(0.2541521788), f32(0.2581829131), f32(0.2622507215), f32(0.2663556635), f32(0.2704978585), f32(0.2746773660),
    f32(0.2788943350), f32(0.2831487954), f32(0.2874408960), f32(0.2917706966), f32(0.2961383164), f32(0.3005438447), f32(0.3049873710), f32(0.3094689548),
    f32(0.3139887452), f32(0.3185468316), f32(0.3231432438), f32(0.3277781308), f32(0.3324515820), f32(0.3371636569), f32(0.3419144452), f32(0.3467040956),
    f32(0.3515326977), f32(0.3564002514), f32(0.3613068759), f32(0.3662526906), f32(0.3712377846), f32(0.3762622178), f32(0.3813261092), f32(0.3864295185),
    f32(0.3915725648), f32(0.3967553079), f32(0.4019778669), f32(0.4072403014), f32(0.4125427008), f32(0.4178851545), f32(0.4232677519), f32(0.4286905527),
    f32(0.4341537058), f32(0.4396572411), f32(0.4452012479), f32(0.4507858455), f32(0.4564110637), f32(0.4620770514), f32(0.4677838385), f32(0.4735315442),
    f32(0.4793202281), f32(0.4851499796), f32(0.4910208881), f32(0.4969330430), f32(0.5028865933), f32(0.5088814497), f32(0.5149177909), f32(0.5209956765),
    f32(0.5271152258), f32(0.5332764983), f32(0.5394796133), f32(0.5457245708), f32(0.5520114899), f32(0.5583404899), f32(0.5647116303), f32(0.5711249113),
    f32(0.5775805116), f32(0.5840784907), f32(0.5906189084), f32(0.5972018838), f32(0.6038274169), f32(0.6104956269), f32(0.6172066331), f32(0.6239604354),
    f32(0.6307572126), f32(0.6375969648), f32(0.6444797516), f32(0.6514056921), f32(0.6583748460), f32(0.6653873324), f32(0.6724432111), f32(0.6795425415),
    f32(0.6866854429), f32(0.6938719153), f32(0.7011020184), f32(0.7083759308), f32(0.7156936526), f32(0.7230552435), f32(0.7304608822), f32(0.7379105687),
    f32(0.7454043627), f32(0.7529423237), f32(0.7605246305), f32(0.7681512833), f32(0.7758223414), f32(0.7835379243), f32(0.7912980318), f32(0.7991028428),
    f32(0.8069523573), f32(0.8148466945), f32(0.8227858543), f32(0.8307699561), f32(0.8387991190), f32(0.8468732834), f32(0.8549926877), f32(0.8631572723),
    f32(0.8713672161), f32(0.8796223402), f32(0.8879231811), f32(0.8962693810), f32(0.9046613574), f32(0.9130986929), f32(0.9215820432), f32(0.9301108718),
    f32(0.9386858940), f32(0.9473065734), f32(0.9559735060), f32(0.9646862745), f32(0.9734454751), f32(0.9822505713), f32(0.9911022186), f32(1.0000000000),
]


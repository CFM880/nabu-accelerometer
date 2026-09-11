/* SPDX-License-Identifier: GPL-3.0-or-later */
#include "nabu-light-filter.h"

static void
test_noise (void)
{
	NabuLightFilter filter = { 0 };
	const double noise[] = { 80.4, 72.1, 57.2, 63.9, 57.9, 66.5,
	                         47.5, 56.5, 50.8, 58.4, 67.8, 60.2, 70.1, 88.8 };
	g_assert_true (nabu_light_filter_sample (&filter, 65, 0));
	for (int t = 1; t <= 180; t++) {
		g_assert_false (nabu_light_filter_sample (&filter,
		                noise[(t / 2) % G_N_ELEMENTS (noise)], t * G_USEC_PER_SEC));
		g_assert_false (nabu_light_filter_poll (&filter, t * G_USEC_PER_SEC));
	}
}

static void
test_steps (void)
{
	/* Only one event at each transition: SSC need not repeat a stable value. */
	for (int rising = 0; rising <= 1; rising++) {
		NabuLightFilter filter = { 0 };
		double initial = rising ? 10 : 200;
		double target = rising ? 200 : 10;
		nabu_light_filter_sample (&filter, initial, 0);
		nabu_light_filter_sample (&filter, target, G_USEC_PER_SEC);
		int first = 0;
		for (int tick = 4; tick <= 180 * 4; tick++) {
			double t = tick / 4.0;
			double before = filter.published;
			if (nabu_light_filter_poll (&filter, t * G_USEC_PER_SEC)) {
				if (!first)
					first = t;
				g_assert_true (rising ? filter.published > before : filter.published < before);
				g_assert_cmpfloat (fabs (filter.published - before), <=, MAX (0.5, before * .06) * .25 + 1e-9);
			}
		}
		g_assert_cmpint (first, >=, rising ? 3 : 9);
		g_assert_cmpint (first, <=, rising ? 6 : 15);
		g_assert_cmpfloat (fabs (filter.published - target), <=, MAX (4, target * .25));
	}
}

static void
test_occlusion (void)
{
	NabuLightFilter filter = { 0 };
	nabu_light_filter_sample (&filter, 70, 0);
	for (int t = 1; t <= 60; t++) {
		/* Repeated three-second hand shadows must not dim the screen. */
		nabu_light_filter_sample (&filter, t % 10 < 3 ? 0 : 70, t * G_USEC_PER_SEC);
		g_assert_false (nabu_light_filter_poll (&filter, t * G_USEC_PER_SEC));
	}
}

static void
test_invalid_and_reset (void)
{
	NabuLightFilter filter = { 0 };
	g_assert_false (nabu_light_filter_sample (&filter, NAN, 0));
	g_assert_false (nabu_light_filter_sample (&filter, INFINITY, 0));
	g_assert_false (nabu_light_filter_sample (&filter, -1, 0));
	g_assert_false (nabu_light_filter_poll (&filter, G_USEC_PER_SEC));
	g_assert_true (nabu_light_filter_sample (&filter, 0, G_USEC_PER_SEC));
	g_assert_false (nabu_light_filter_sample (&filter, NAN, 2 * G_USEC_PER_SEC));
	g_assert_cmpfloat (filter.raw, ==, 0);
	filter = (NabuLightFilter) { 0 }; /* Release/reclaim starts from fresh data. */
	g_assert_true (nabu_light_filter_sample (&filter, 300, 10 * G_USEC_PER_SEC));
	g_assert_cmpfloat (filter.published, ==, 300);
}

static void
test_small_transient (void)
{
	NabuLightFilter filter = { 0 };
	nabu_light_filter_sample (&filter, 60, 0);
	for (int tick = 1; tick <= 120 * 4; tick++) {
		gint64 now = tick * (G_USEC_PER_SEC / 4);
		/* Five-second fluctuations must not initiate a ramp. */
		nabu_light_filter_sample (&filter, (tick / 20) % 2 ? 100 : 60, now);
		g_assert_false (nabu_light_filter_poll (&filter, now));
	}
}

static void
test_stall_and_frequency (void)
{
	NabuLightFilter filter = { 0 };
	nabu_light_filter_sample (&filter, 60, 0);
	nabu_light_filter_sample (&filter, 600, G_USEC_PER_SEC);
	nabu_light_filter_poll (&filter, 10 * G_USEC_PER_SEC);
	double before = filter.published;
	g_assert_true (nabu_light_filter_poll (&filter, 100 * G_USEC_PER_SEC));
	g_assert_cmpfloat (filter.published - before, <=, before * .015 + 1e-9);
	before = filter.published;
	for (int ms = 1; ms < 250; ms++)
		g_assert_false (nabu_light_filter_poll (&filter, 100 * G_USEC_PER_SEC + ms * 1000));
	g_assert_cmpfloat (filter.published, ==, before);
}

int
main (int argc, char **argv)
{
	g_test_init (&argc, &argv, NULL);
	g_test_add_func ("/light/noise", test_noise);
	g_test_add_func ("/light/steps", test_steps);
	g_test_add_func ("/light/occlusion", test_occlusion);
	g_test_add_func ("/light/invalid-reset", test_invalid_and_reset);
	g_test_add_func ("/light/small-transient", test_small_transient);
	g_test_add_func ("/light/stall-frequency", test_stall_and_frequency);
	return g_test_run ();
}

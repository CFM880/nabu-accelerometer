/* SPDX-License-Identifier: GPL-3.0-or-later */
#pragma once

#include <glib.h>
#include <math.h>

/* SSC reports on change, so advance this filter on a monotonic timer too.
 * A quiet sensor retains its last valid reading; repeated events are not
 * required to confirm a sustained change. All timestamps are microseconds. */
typedef struct {
	gboolean initialized;
	double raw, smoothed, target, published;
	gint64 updated_at, pending_since, output_at;
	int pending_direction;
} NabuLightFilter;

static inline void
nabu_light_filter_advance (NabuLightFilter *filter, gint64 now)
{
	if (!filter->initialized || now <= filter->updated_at)
		return;
	double dt = (now - filter->updated_at) / (double) G_USEC_PER_SEC;
	double tau = filter->raw > filter->smoothed ? 2.0 : 5.0;
	filter->smoothed += (filter->raw - filter->smoothed) * (1.0 - exp (-dt / tau));
	filter->updated_at = now;
}

static inline gboolean
nabu_light_filter_sample (NabuLightFilter *filter, double lux, gint64 now)
{
	if (!isfinite (lux) || lux < 0)
		return FALSE;
	if (!filter->initialized) {
		*filter = (NabuLightFilter) {
			.initialized = TRUE,
			.raw = lux, .smoothed = lux, .target = lux, .published = lux,
			.updated_at = now, .output_at = now,
		};
		return TRUE; /* Do not delay sensor startup. */
	}
	nabu_light_filter_advance (filter, now);
	filter->raw = lux;
	return FALSE;
}

/* Keep target confirmation separate from output. Otherwise every accepted
 * reading becomes a visible jump, especially after a long D-Bus silence. */
static inline void
nabu_light_filter_select_target (NabuLightFilter *filter, gint64 now)
{
	double margin = MAX (4.0, filter->target * 0.25);
	int direction = 0;
	if (filter->smoothed > filter->target + margin &&
	    filter->raw > filter->target + margin)
		direction = 1;
	else if (filter->smoothed < filter->target - margin &&
	         filter->raw < filter->target - margin)
		direction = -1;
	if (!direction) {
		filter->pending_direction = 0;
		return;
	}
	if (direction != filter->pending_direction) {
		filter->pending_direction = direction;
		filter->pending_since = now;
		return;
	}
	gboolean large = direction > 0 ? filter->smoothed > MAX (4.0, filter->target) * 2.0
	                              : filter->smoothed < filter->target / 2.0;
	gint64 dwell = (direction > 0 ? (large ? 2 : 6) : (large ? 8 : 12)) * G_USEC_PER_SEC;
	if (now - filter->pending_since < dwell)
		return;
	filter->target = filter->smoothed;
	filter->pending_direction = 0;
}

static inline gboolean
nabu_light_filter_poll (NabuLightFilter *filter, gint64 now)
{
	if (!filter->initialized)
		return FALSE;
	nabu_light_filter_advance (filter, now);
	nabu_light_filter_select_target (filter, now);
	if (now <= filter->output_at)
		return FALSE;
	/* Cap elapsed time so a stalled main loop cannot release a large jump.
	 * Ignore sub-250ms calls; raw SSC event frequency must not set ramp speed. */
	double dt = (now - filter->output_at) / (double) G_USEC_PER_SEC;
	if (dt < 0.25)
		return FALSE;
	dt = MIN (dt, 0.25);
	filter->output_at = now;
	double delta = filter->target - filter->published;
	double step = MAX (0.5, filter->published * 0.06) * dt;
	if (fabs (delta) < 0.000001)
		return FALSE;
	filter->published += CLAMP (delta, -step, step);
	return TRUE;
}

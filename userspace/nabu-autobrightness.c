// SPDX-License-Identifier: GPL-2.0-only
/*
 * nabu: fixed-curve automatic brightness.
 *
 * GNOME 48 does not use a fixed lux -> brightness table: it scales the
 * backlight relative to the last manually chosen level, so after a large
 * ambient swing the reference ends up somewhere else and the panel does not
 * come back to its previous brightness (and low light is far too dim).
 *
 * This daemon maps the ambient light sensor to a fixed curve and applies the
 * result through gnome-settings-daemon on the session bus, so the OSD, the
 * slider and the persistence keep working.  gsd's own ambient support is
 * switched off (org.gnome.settings-daemon.plugins.power ambient-enabled=false)
 * so the two do not fight.
 *
 * Details: nabu-linux-overlay/docs/port-6.18.md
 */
#include <gio/gio.h>
#include <math.h>

#define SENSOR_NAME	"net.hadess.SensorProxy"
#define SENSOR_PATH	"/net/hadess/SensorProxy"
#define POWER_NAME	"org.gnome.SettingsDaemon.Power"
#define POWER_PATH	"/org/gnome/SettingsDaemon/Power"
#define SCREEN_IFACE	"org.gnome.SettingsDaemon.Power.Screen"

#define TICK_MS		250
/* output slew: percent per second, with a floor so the last steps are quick */
#define SLEW_FRACTION	0.5
#define SLEW_MIN	1.0

static const struct {
	double lux;
	double pct;
} curve[] = {
	/* 1600x2560 panel, 2047 backlight steps.  Tuned for a living room
	 * (~20-40 lux) to sit around 40 %, brightening to full outdoors. */
	{ 0.0,     8.0 },
	{ 2.0,    14.0 },
	{ 5.0,    20.0 },
	{ 10.0,   26.0 },
	{ 20.0,   38.0 },
	{ 50.0,   50.0 },
	{ 100.0,  60.0 },
	{ 300.0,  72.0 },
	{ 1000.0, 85.0 },
	{ 3000.0, 100.0 },
};

static GDBusProxy *sensor_proxy;
static GDBusProxy *power_proxy;
static double target = -1.0;
static double current = -1.0;

static double
lux_to_pct (double lux)
{
	gsize i;

	if (!isfinite (lux) || lux < 0)
		return -1.0;

	if (lux <= curve[0].lux)
		return curve[0].pct;

	for (i = 1; i < G_N_ELEMENTS (curve); i++) {
		double l0 = curve[i - 1].lux, l1 = curve[i].lux;
		double p0 = curve[i - 1].pct, p1 = curve[i].pct;
		double t;

		if (lux > l1)
			continue;

		/* interpolate in log(lux): the curve is roughly exponential */
		if (lux <= l0)
			return p0;
		t = (log (lux + 1.0) - log (l0 + 1.0)) /
		    (log (l1 + 1.0) - log (l0 + 1.0));
		return p0 + t * (p1 - p0);
	}

	return curve[G_N_ELEMENTS (curve) - 1].pct;
}

static void
apply_brightness (int pct)
{
	if (!power_proxy)
		return;

	g_dbus_proxy_call (power_proxy,
			   "org.freedesktop.DBus.Properties.Set",
			   g_variant_new ("(ssv)", SCREEN_IFACE, "Brightness",
					  g_variant_new_int32 (pct)),
			   G_DBUS_CALL_FLAGS_NONE, -1, NULL, NULL, NULL);
}

static void read_light_level (void);

/*
 * iio-sensor-proxy is restarted by the sensor resume hook after a suspend, so
 * the claim (and with it the sensor) is lost.  Re-claiming is idempotent; the
 * LightLevel property then starts flowing again.
 */
static gboolean
reclaim (gpointer user_data)
{
	GError *error = NULL;

	(void) user_data;

	g_dbus_proxy_call_sync (sensor_proxy, "ClaimLight", NULL,
				G_DBUS_CALL_FLAGS_NONE, -1, NULL, &error);
	if (error) {
		g_debug ("re-claim failed: %s", error->message);
		g_clear_error (&error);
	}

	read_light_level ();

	return G_SOURCE_CONTINUE;
}

static gboolean
tick (gpointer user_data)
{
	double step;

	(void) user_data;

	if (target < 0.0)
		return G_SOURCE_CONTINUE;

	if (current < 0.0)
		current = target;

	step = MAX (SLEW_MIN, current * SLEW_FRACTION) / (1000.0 / TICK_MS);

	if (fabs (target - current) <= step) {
		current = target;
	} else {
		current += target > current ? step : -step;
	}

	apply_brightness ((int) round (current));

	return G_SOURCE_CONTINUE;
}

static void
read_light_level (void)
{
	GVariant *value;
	double lux;
	int pct;

	value = g_dbus_proxy_get_cached_property (sensor_proxy, "LightLevel");
	if (!value)
		return;

	lux = g_variant_get_double (value);
	g_variant_unref (value);

	pct = (int) round (lux_to_pct (lux));
	if (pct < 0)
		return;

	/* Follow the sensor down immediately, climb gently: a shadow is not a
	 * reason to flash the panel, and the eye adapts slowly upwards. */
	if (current < 0.0) {
		current = pct;
		apply_brightness (pct);
	}

	target = pct;
}

static void
sensor_properties_changed (GDBusProxy *proxy, GVariant *changed,
			   GStrv invalidated, gpointer user_data)
{
	(void) proxy;
	(void) user_data;

	if (g_variant_lookup_value (changed, "LightLevel", NULL) ||
	    g_strv_contains ((const gchar * const *) invalidated, "LightLevel"))
		read_light_level ();
}

int
main (int argc, char **argv)
{
	GMainLoop *loop;

	(void) argc;
	(void) argv;
	GVariant *has_light;
	GError *error = NULL;

	sensor_proxy = g_dbus_proxy_new_for_bus_sync (G_BUS_TYPE_SYSTEM,
						      G_DBUS_PROXY_FLAGS_NONE,
						      NULL, SENSOR_NAME, SENSOR_PATH,
						      "org.freedesktop.DBus.Properties",
						      NULL, &error);
	if (!sensor_proxy) {
		g_warning ("no ambient light sensor proxy: %s", error->message);
		g_error_free (error);
		return 1;
	}

	/* iio-sensor-proxy only enables the light sensor while a client holds the
	 * claim (gsd used to do that for its own ambient support), so claim it
	 * ourselves before reading anything. */
	g_dbus_proxy_call_sync (sensor_proxy, "ClaimLight", NULL,
				G_DBUS_CALL_FLAGS_NONE, -1, NULL, &error);
	if (error) {
		g_message ("cannot claim the ambient light sensor: %s",
			   error->message);
		g_clear_error (&error);
		return 1;
	}

	has_light = g_dbus_proxy_get_cached_property (sensor_proxy, "HasAmbientLight");
	if (!has_light || !g_variant_get_boolean (has_light)) {
		g_message ("no ambient light sensor, nothing to do");
		g_clear_pointer (&has_light, g_variant_unref);
		return 0;
	}
	g_variant_unref (has_light);

	power_proxy = g_dbus_proxy_new_for_bus_sync (G_BUS_TYPE_SESSION,
						     G_DBUS_PROXY_FLAGS_NONE,
						     NULL, POWER_NAME, POWER_PATH,
						     "org.freedesktop.DBus.Properties",
						     NULL, &error);
	if (!power_proxy) {
		g_warning ("no gnome-settings-daemon power proxy: %s",
			   error->message);
		g_error_free (error);
		return 1;
	}

	g_signal_connect (sensor_proxy, "g-properties-changed",
			  G_CALLBACK (sensor_properties_changed), NULL);

	read_light_level ();
	g_timeout_add (TICK_MS, tick, NULL);
	g_timeout_add_seconds (30, reclaim, NULL);

	loop = g_main_loop_new (NULL, FALSE);
	g_main_loop_run (loop);

	return 0;
}

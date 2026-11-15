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
static GDBusConnection *system_bus;

static gboolean
claim_light (GError **error)
{
	GVariant *ret;

	ret = g_dbus_proxy_call_sync (sensor_proxy, "ClaimLight", NULL,
				      G_DBUS_CALL_FLAGS_NONE, -1, NULL, error);
	if (!ret)
		return FALSE;

	g_variant_unref (ret);
	return TRUE;
}
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

static int applied = -1;

/*
 * The proxies are bound to the service interfaces (net.hadess.SensorProxy and
 * org.gnome.SettingsDaemon.Power.Screen): GLib only delivers a
 * PropertiesChanged signal when the interface in the signal matches the
 * proxy's own interface, and binding them to org.freedesktop.DBus.Properties
 * silently drops every light change (brightness then only moved on the 30 s
 * timer).  Values are still read and written through the standard Properties
 * interface, which the proxies cannot address.
 */
static GVariant *
get_property (GDBusProxy *proxy, const char *iface, const char *name)
{
	GVariant *ret, *value = NULL;

	ret = g_dbus_connection_call_sync (g_dbus_proxy_get_connection (proxy),
					   g_dbus_proxy_get_name (proxy),
					   g_dbus_proxy_get_object_path (proxy),
					   "org.freedesktop.DBus.Properties",
					   "Get", g_variant_new ("(ss)", iface, name),
					   G_VARIANT_TYPE ("(v)"),
					   G_DBUS_CALL_FLAGS_NONE, -1, NULL, NULL);
	if (!ret)
		return NULL;

	g_variant_get (ret, "(v)", &value);
	g_variant_unref (ret);

	return value;
}

static void
apply_brightness (int pct)
{
	if (!power_proxy || pct == applied)
		return;

	applied = pct;
	g_debug ("set backlight %d%%", pct);

	g_dbus_connection_call (g_dbus_proxy_get_connection (power_proxy),
				POWER_NAME, POWER_PATH,
				"org.freedesktop.DBus.Properties", "Set",
				g_variant_new ("(ssv)", SCREEN_IFACE, "Brightness",
					       g_variant_new_int32 (pct)),
				NULL, G_DBUS_CALL_FLAGS_NONE, -1, NULL, NULL,
				NULL);
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

	if (!claim_light (&error)) {
		g_debug ("re-claim failed: %s", error->message);
		g_clear_error (&error);
	}

	read_light_level ();

	return G_SOURCE_CONTINUE;
}

static gboolean
has_light_sensor (void)
{
	GVariant *value = get_property (sensor_proxy, SENSOR_NAME,
					"HasAmbientLight");
	gboolean has;

	if (!value)
		return FALSE;

	has = g_variant_get_boolean (value);
	g_variant_unref (value);

	return has;
}

static gboolean
reclaim_once (gpointer user_data)
{
	reclaim (user_data);
	return G_SOURCE_REMOVE;
}

/*
 * A change we did not make ourselves (gsd re-applies its stored brightness on
 * resume, for example) leaves the panel at a level the curve does not want
 * while our target is unchanged, so nothing would ever correct it.  Adopt the
 * real level as the starting point and force the next tick to write again.
 */
static void
resync (void)
{
	GVariant *value;
	int actual;

	value = get_property (power_proxy, SCREEN_IFACE, "Brightness");
	if (!value)
		return;

	actual = g_variant_get_int32 (value);
	g_variant_unref (value);

	if (actual == applied)
		return;

	current = actual;
	applied = -1;
}

static void
logind_prepare_for_sleep (GDBusConnection *connection, const char *sender,
			  const char *object_path, const char *interface_name,
			  const char *signal_name, GVariant *parameters,
			  gpointer user_data)
{
	gboolean sleeping;

	(void) connection;
	(void) sender;
	(void) object_path;
	(void) interface_name;
	(void) signal_name;
	(void) user_data;

	g_variant_get (parameters, "(b)", &sleeping);
	if (sleeping)
		return;

	resync ();

	return;
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
apply_lux (double lux)
{
	GVariant *value;
	int pct;

	pct = (int) round (lux_to_pct (lux));
	if (pct < 0 || pct == (int) target)
		return;

	g_message ("lux %.2f -> %d%% (was %.0f%%, applied %d%%)",
		   lux, pct, target, applied);

	/* Continue from the level the panel actually shows: the user may have
	 * moved the slider since the last sensor event, and the fade should
	 * start where the eye is, not where the previous ramp ended. */
	value = get_property (power_proxy, SCREEN_IFACE, "Brightness");
	if (value) {
		current = g_variant_get_int32 (value);
		g_variant_unref (value);
	}

	if (current < 0.0)
		current = pct;	/* unknown level: no fade-in */

	target = pct;
}

static void
read_light_level (void)
{
	GVariant *value;
	double lux;

	value = get_property (sensor_proxy, SENSOR_NAME, "LightLevel");
	if (!value)
		return;

	lux = g_variant_get_double (value);
	g_variant_unref (value);

	apply_lux (lux);
}

static void
sensor_properties_changed (GDBusProxy *proxy, GVariant *changed,
			   GStrv invalidated, gpointer user_data)
{
	GVariant *value;

	(void) proxy;
	(void) user_data;

	value = g_variant_lookup_value (changed, "LightLevel",
					G_VARIANT_TYPE_DOUBLE);
	if (value) {
		apply_lux (g_variant_get_double (value));
		g_variant_unref (value);
		return;
	}

	if (invalidated && g_strv_contains ((const gchar * const *) invalidated,
					    "LightLevel"))
		read_light_level ();
}

int
main (int argc, char **argv)
{
	GMainLoop *loop;

	(void) argc;
	(void) argv;
	GError *error = NULL;

	system_bus = g_bus_get_sync (G_BUS_TYPE_SYSTEM, NULL, &error);
	if (!system_bus) {
		g_warning ("no system bus: %s", error->message);
		g_error_free (error);
		return 1;
	}

	sensor_proxy = g_dbus_proxy_new_for_bus_sync (G_BUS_TYPE_SYSTEM,
						      G_DBUS_PROXY_FLAGS_NONE,
						      NULL, SENSOR_NAME, SENSOR_PATH,
						      SENSOR_NAME, NULL, &error);
	if (!sensor_proxy) {
		g_warning ("no ambient light sensor proxy: %s", error->message);
		g_error_free (error);
		return 1;
	}

	/* iio-sensor-proxy only enables the light sensor while a client holds the
	 * claim (gsd used to do that for its own ambient support), so claim it
	 * ourselves before reading anything. */
	if (!claim_light (&error)) {
		g_message ("cannot claim the ambient light sensor: %s",
			   error->message);
		g_clear_error (&error);
		return 1;
	}

	/* The sensor only appears a moment after the claim, so do not treat a
	 * missing HasAmbientLight here as fatal: the timers below keep checking
	 * and LightLevel starts flowing once iio-sensor-proxy has opened it. */
	if (!has_light_sensor ())
		g_message ("ambient light sensor not ready yet, waiting");

	power_proxy = g_dbus_proxy_new_for_bus_sync (G_BUS_TYPE_SESSION,
						     G_DBUS_PROXY_FLAGS_NONE,
						     NULL, POWER_NAME, POWER_PATH,
						     SCREEN_IFACE, NULL, &error);
	if (!power_proxy) {
		g_warning ("no gnome-settings-daemon power proxy: %s",
			   error->message);
		g_error_free (error);
		return 1;
	}

	g_signal_connect (sensor_proxy, "g-properties-changed",
			  G_CALLBACK (sensor_properties_changed), NULL);

	/* gsd restores its stored brightness on resume, so take over again as
	 * soon as logind reports that the system is awake. */
	g_dbus_connection_signal_subscribe (system_bus, "org.freedesktop.login1",
					    "org.freedesktop.login1.Manager",
					    "PrepareForSleep",
					    "/org/freedesktop/login1", NULL,
					    G_DBUS_SIGNAL_FLAGS_NONE,
					    logind_prepare_for_sleep, NULL, NULL);

	read_light_level ();
	g_timeout_add (TICK_MS, tick, NULL);
	/* First reading a moment later: the sensor is only opened after the
	 * claim, and without an event the curve would not be applied at all. */
	g_timeout_add (1500, reclaim_once, NULL);
	g_timeout_add_seconds (30, reclaim, NULL);

	loop = g_main_loop_new (NULL, FALSE);
	g_main_loop_run (loop);

	return 0;
}

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
 * Behaviour, chosen on hardware:
 *
 * - the panel keeps its current level while the light is changing, and moves
 *   once the reading has been stable for SETTLE_MS.  Chasing every sensor step
 *   looked like flicker, and waiting is what makes the change feel deliberate;
 * - the move itself is linear at one percent per tick (both directions), so it
 *   arrives quickly and evenly, like dragging the slider;
 * - differences below DEADBAND are ignored, so sensor noise around a curve
 *   knee no longer steps the backlight by one percent back and forth.
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

#define IDLE_NAME	"org.gnome.Mutter.IdleMonitor"
#define IDLE_PATH	"/org/gnome/Mutter/IdleMonitor/Core"

/* how long the light has to stay put before the panel follows it */
#define SETTLE_MS	800
/* the move after that: one percent per tick, i.e. 25 %/s */
#define RAMP_TICK_MS	40
/* the panel is left alone while the curve is this close to what it shows */
#define DEADBAND	2
/* a change this soon after input is the user moving the slider */
#define MANUAL_WINDOW_MS 2000
/* how often the panel is compared with what we asked for */
#define CHECK_MS	2000
/* the sensor is re-claimed this often (the resume hook restarts the proxy) */
#define RECLAIM_SECONDS	30
/*
 * A manual level is kept until the curve itself has moved meaningfully, i.e.
 * until the ambient light changed enough for the curve to be this far away.
 */
#define OVERRIDE_HYSTERESIS 5

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

/* last value written to gsd; -1 while unknown */
static int applied = -1;
/* position of the running move, in percent */
static double current = -1.0;
/* value the running move is heading to, -1 when idle */
static int ramp_target = -1;
/* value waiting for the light to settle, -1 when idle */
static int pending_pct = -1;

static guint settle_source;
static guint ramp_source;

static gboolean override;
static int override_pct;
static double last_lux = -1.0;

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

static guint64
idle_time_ms (void)
{
	GError *error = NULL;
	GVariant *ret;
	guint64 idle;

	ret = g_dbus_connection_call_sync (g_dbus_proxy_get_connection (power_proxy),
					   IDLE_NAME, IDLE_PATH,
					   "org.gnome.Mutter.IdleMonitor",
					   "GetIdletime", NULL,
					   G_VARIANT_TYPE ("(t)"),
					   G_DBUS_CALL_FLAGS_NONE, 500, NULL,
					   &error);
	if (!ret) {
		g_debug ("no idle time: %s", error->message);
		g_clear_error (&error);
		return G_MAXUINT64;
	}

	g_variant_get (ret, "(t)", &idle);
	g_variant_unref (ret);

	return idle;
}

/*
 * The proxies are bound to the service interfaces (net.hadess.SensorProxy and
 * org.gnome.SettingsDaemon.Power.Screen): GLib only delivers a
 * PropertiesChanged signal when the interface in the signal matches the
 * proxy's own interface, and binding them to org.freedesktop.DBus.Properties
 * silently drops every light change (brightness then only moved on the re-claim
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
	GVariant *ret;

	if (!power_proxy || pct == applied)
		return;

	applied = pct;
	g_debug ("set backlight %d%%", pct);

	/*
	 * Synchronous on purpose: gsd applies back-to-back Sets out of order
	 * when a move sends them faster than it consumes them (the panel went
	 * 78 -> 79 -> 78 while the writes were 79, 78, 77), which shows up as a
	 * visible jump.  One round trip is ~1 ms, so waiting is free here.
	 */
	ret = g_dbus_connection_call_sync (g_dbus_proxy_get_connection (power_proxy),
					   POWER_NAME, POWER_PATH,
					   "org.freedesktop.DBus.Properties", "Set",
					   g_variant_new ("(ssv)", SCREEN_IFACE, "Brightness",
							  g_variant_new_int32 (pct)),
					   NULL, G_DBUS_CALL_FLAGS_NONE, 200, NULL,
					   NULL);
	if (ret)
		g_variant_unref (ret);
}

/*
 * gsd's own ambient support scales the backlight relative to the last manual
 * level; when it is enabled it keeps writing the backlight behind our back (a
 * lamp being switched off made the panel fall from 74 % to 36 % while this
 * daemon was ramping up).  The key is user state and can be switched back on by
 * a session restart or by the settings panel, so enforce it at every start.
 */
static void
disable_gsd_ambient (void)
{
	GSettings *settings;

	settings = g_settings_new ("org.gnome.settings-daemon.plugins.power");
	if (g_settings_get_boolean (settings, "ambient-enabled")) {
		g_message ("gsd ambient brightness was enabled, switching it off");
		g_settings_set_boolean (settings, "ambient-enabled", FALSE);
	}
	g_object_unref (settings);
}

static void
cancel_settle (void)
{
	if (settle_source) {
		g_source_remove (settle_source);
		settle_source = 0;
	}

	pending_pct = -1;
}

static void
cancel_ramp (void)
{
	if (ramp_source) {
		g_source_remove (ramp_source);
		ramp_source = 0;
	}

	ramp_target = -1;
}

/*
 * One percent per tick, in the direction of the target: the move is linear and
 * short (a 40 point change takes 1.6 s), which is what the eye reads as "it
 * went to the right level" rather than as a fade.
 */
static gboolean
ramp_tick (gpointer user_data)
{
	(void) user_data;

	if (ramp_target < 0) {
		ramp_source = 0;
		return G_SOURCE_REMOVE;
	}

	if (current < 0.0)
		current = applied < 0 ? 0 : applied;

	if ((int) current == ramp_target) {
		ramp_source = 0;
		ramp_target = -1;
		return G_SOURCE_REMOVE;
	}

	current += ramp_target > current ? 1 : -1;
	apply_brightness ((int) current);

	return G_SOURCE_CONTINUE;
}

static gboolean
settle_done (gpointer user_data)
{
	(void) user_data;

	settle_source = 0;

	if (pending_pct < 0)
		return G_SOURCE_REMOVE;

	if (ABS (pending_pct - applied) < DEADBAND) {
		pending_pct = -1;
		return G_SOURCE_REMOVE;
	}

	g_message ("light stable: %d%% -> %d%%", applied, pending_pct);

	if (applied < 0) {
		/* nothing on the panel yet (first reading): no move to make */
		current = pending_pct;
		apply_brightness (pending_pct);
		pending_pct = -1;
		return G_SOURCE_REMOVE;
	}

	current = applied;
	ramp_target = pending_pct;
	pending_pct = -1;

	if (!ramp_source)
		ramp_source = g_timeout_add (RAMP_TICK_MS, ramp_tick, NULL);

	return G_SOURCE_REMOVE;
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
 * while the curve target itself is unchanged, so nothing would ever correct
 * it.  Adopt the real level and let the next reading move on from there.
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

	cancel_settle ();
	cancel_ramp ();
	override = FALSE;

	if (actual == applied)
		return;

	current = actual;
	applied = -1;
}

static int pending_external = -1;

/*
 * gsd's Brightness notifications cannot be trusted while we are moving the
 * panel: they lag behind what we asked for (75 % reported while the panel was
 * already at 82 %).  Check the panel on a slow timer instead: only a value that
 * differs from what we last set and survives two checks in a row is a real
 * external change.
 */
static gboolean
check_external (gpointer user_data)
{
	GVariant *value;
	int brightness;
	int curved;

	(void) user_data;

	if (ramp_source || last_lux < 0.0) {
		pending_external = -1;
		return G_SOURCE_CONTINUE;
	}

	value = get_property (power_proxy, SCREEN_IFACE, "Brightness");
	if (!value)
		return G_SOURCE_CONTINUE;

	brightness = g_variant_get_int32 (value);
	g_variant_unref (value);

	/* gsd re-derives its percentage from the raw backlight: a point or two
	 * off is its own rounding, not a change */
	if (ABS (brightness - applied) <= 2) {
		pending_external = -1;
		return G_SOURCE_CONTINUE;
	}

	if (pending_external != brightness) {
		pending_external = brightness;
		return G_SOURCE_CONTINUE;
	}

	pending_external = -1;
	curved = (int) round (lux_to_pct (last_lux));

	if (idle_time_ms () <= MANUAL_WINDOW_MS) {
		g_message ("manual level %d%% (curve would give %d%% at %.2f lux)",
			   brightness, curved, last_lux);
		cancel_settle ();
		cancel_ramp ();
		override = TRUE;
		override_pct = curved;
		current = brightness;
		applied = brightness;
		return G_SOURCE_CONTINUE;
	}

	g_message ("external %d%% while the user is away (curve %d%%), restoring",
		   brightness, curved);
	cancel_settle ();
	cancel_ramp ();
	override = FALSE;
	current = brightness;
	applied = -1;
	pending_pct = curved;
	settle_source = g_timeout_add (SETTLE_MS, settle_done, NULL);

	return G_SOURCE_CONTINUE;
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
}

/*
 * Sensor reading in: remember the target and (re)start the settle timer.  The
 * panel is not touched until the light stops moving, so a lamp being switched
 * on does not drag the brightness through every intermediate level.
 */
static void
apply_lux (double lux)
{
	int pct;
	int reference;

	pct = (int) round (lux_to_pct (lux));
	if (pct < 0)
		return;

	last_lux = lux;

	if (override) {
		if (ABS (pct - override_pct) < OVERRIDE_HYSTERESIS)
			return;
		g_message ("ambient moved %d%% -> %d%%, dropping the manual level",
			   override_pct, pct);
		override = FALSE;
	}

	reference = ramp_target >= 0 ? ramp_target : applied;

	if (ABS (pct - reference) < DEADBAND) {
		/* small wobble around the current level: leave the panel alone */
		cancel_settle ();
		return;
	}

	pending_pct = pct;

	if (settle_source)
		g_source_remove (settle_source);

	settle_source = g_timeout_add (SETTLE_MS, settle_done, NULL);
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
	GError *error = NULL;

	(void) argc;
	(void) argv;

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

	disable_gsd_ambient ();

	g_timeout_add (CHECK_MS, check_external, NULL);
	g_timeout_add_seconds (RECLAIM_SECONDS, reclaim, NULL);

	read_light_level ();
	/* First reading a moment later: the sensor is only opened after the
	 * claim, and without an event the curve would not be applied at all. */
	g_timeout_add (1500, reclaim_once, NULL);

	loop = g_main_loop_new (NULL, FALSE);
	g_main_loop_run (loop);

	return 0;
}

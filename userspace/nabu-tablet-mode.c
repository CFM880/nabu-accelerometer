// SPDX-License-Identifier: GPL-2.0-only
#define _GNU_SOURCE

#include <errno.h>
#include <dirent.h>
#include <fcntl.h>
#include <linux/input-event-codes.h>
#include <linux/input.h>
#include <linux/uinput.h>
#include <signal.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/stat.h>
#include <systemd/sd-bus.h>
#include <time.h>
#include <unistd.h>

#define DEVICE_NAME "Nabu Tablet Mode Switch"
#define ACCEL_SERVICE "net.hadess.SensorProxy"
#define ACCEL_INTERFACE "net.hadess.SensorProxy"

/* Shell poll / bus wait granularity, and fallback if no Claim ever arrives. */
#define POLL_USEC 200000ULL		/* 200 ms */
#define CLAIM_TIMEOUT_USEC 30000000ULL	/* 30 s: accelerometer proxy absent */
#define MONITOR_RETRY_USEC 5000000ULL

static volatile sig_atomic_t stopping;

static void handle_signal(int signal_number)
{
	(void)signal_number;
	stopping = 1;
}

static uint64_t now_us(void)
{
	struct timespec ts;

	clock_gettime(CLOCK_MONOTONIC, &ts);
	return (uint64_t)ts.tv_sec * 1000000ULL +
	       (uint64_t)ts.tv_nsec / 1000ULL;
}

static int sleep_us(uint64_t usec)
{
	struct timespec delay = {
		.tv_sec = (time_t)(usec / 1000000ULL),
		.tv_nsec = (long)((usec % 1000000ULL) * 1000ULL),
	};

	while (!stopping && nanosleep(&delay, &delay) < 0 && errno == EINTR)
		;

	return stopping ? -1 : 0;
}

static int emit_event(int fd, unsigned short type, unsigned short code,
		      int value)
{
	struct input_event event = {
		.type = type,
		.code = code,
		.value = value,
	};
	ssize_t written;

	written = write(fd, &event, sizeof(event));
	if (written == (ssize_t)sizeof(event))
		return 0;

	if (written >= 0)
		errno = EIO;
	return -1;
}

static int set_tablet_mode(int fd, bool enabled)
{
	if (emit_event(fd, EV_SW, SW_TABLET_MODE, enabled ? 1 : 0) < 0)
		return -1;

	return emit_event(fd, EV_SYN, SYN_REPORT, 0);
}

enum shell_state {
	SHELL_NONE,
	SHELL_GREETER,
	SHELL_USER,
};

static enum shell_state current_shell_state(void)
{
	struct dirent *entry;
	DIR *proc;
	enum shell_state state = SHELL_NONE;

	proc = opendir("/proc");
	if (!proc)
		return SHELL_NONE;

	while ((entry = readdir(proc))) {
		char path[64];
		char cmdline[256];
		char comm[32];
		struct stat statbuf;
		ssize_t cmdline_length;
		ssize_t length;
		int comm_fd;
		int cmdline_fd;
		char *end;
		long pid;

		pid = strtol(entry->d_name, &end, 10);
		if (*entry->d_name == '\0' || *end != '\0' || pid <= 0)
			continue;

		(void)snprintf(path, sizeof(path), "/proc/%ld", pid);
		if (stat(path, &statbuf) < 0 || statbuf.st_uid < 1000 ||
		    statbuf.st_uid == 65534)
			continue;

		(void)snprintf(path, sizeof(path), "/proc/%ld/comm", pid);
		comm_fd = open(path, O_RDONLY | O_CLOEXEC);
		if (comm_fd < 0)
			continue;
		length = read(comm_fd, comm, sizeof(comm) - 1);
		close(comm_fd);
		if (length <= 0)
			continue;
		comm[length] = '\0';
		if (strcmp(comm, "gnome-shell\n") != 0 &&
		    strcmp(comm, "gnome-shell") != 0)
			continue;

		/*
		 * GDM also runs gnome-shell, commonly under a dynamically
		 * allocated UID above 1000.  The greeter still needs the same
		 * laptop -> tablet transition as a user session: its Mutter
		 * instance ignores the first accelerometer reading while it
		 * initializes the native panel orientation, so without a later
		 * OFF -> ON edge the login screen never rotates.  Report the
		 * greeter separately so main() can restart the cycle when the
		 * user session replaces it.
		 */
		state = SHELL_USER;
		(void)snprintf(path, sizeof(path), "/proc/%ld/cmdline", pid);
		cmdline_fd = open(path, O_RDONLY | O_CLOEXEC);
		if (cmdline_fd >= 0) {
			cmdline_length = read(cmdline_fd, cmdline,
					      sizeof(cmdline));
			close(cmdline_fd);
			if (cmdline_length > 0 &&
			    memmem(cmdline, (size_t)cmdline_length,
				   "--mode=gdm", strlen("--mode=gdm"))) {
				state = SHELL_GREETER;
				continue;
			}
		}

		/* A real user session takes priority over the greeter. */
		break;
	}

	closedir(proc);
	return state;
}

/*
 * Mutter only enables accelerometer based orientation tracking after it has
 * itself claimed the sensor with ClaimAccelerometer (iio-sensor-proxy then
 * starts streaming).  There is no broadcast for that: its PropertiesChanged
 * signals are unicast to claiming clients only.  So instead of polling, watch
 * the system bus as a monitor and react to the method call itself.
 *
 * The monitor needs root, which this unit has.  The connection cannot make
 * method calls afterwards, which is fine: we only listen.
 */
static sd_bus *claim_monitor;

static int start_claim_monitor(void)
{
	static const char match[] =
		"type='method_call',"
		"destination='" ACCEL_SERVICE "',"
		"member='ClaimAccelerometer'";
	sd_bus *bus = NULL;
	sd_bus_error error = SD_BUS_ERROR_NULL;
	int r;

	r = sd_bus_open_system(&bus);
	if (r < 0) {
		fprintf(stderr, DEVICE_NAME ": sd_bus_open_system: %s\n",
			strerror(-r));
		return r;
	}

	/*
	 * Become a bus monitor (root only).  sd_bus_set_monitor() cannot be
	 * used here because the connection returned by sd_bus_open_system() is
	 * already started; the daemon therefore rejects BecomeMonitor at that
	 * point, so issue the call explicitly, like dbus-monitor does.
	 */
	r = sd_bus_call_method(bus,
			       "org.freedesktop.DBus",
			       "/org/freedesktop/DBus",
			       "org.freedesktop.DBus.Monitoring",
			       "BecomeMonitor",
			       &error, NULL, "asu", 1, match, (uint32_t)0);
	if (r < 0) {
		fprintf(stderr, DEVICE_NAME ": BecomeMonitor: %s\n",
			error.message ? error.message : strerror(-r));
		sd_bus_error_free(&error);
		sd_bus_unref(bus);
		return r;
	}
	sd_bus_error_free(&error);

	claim_monitor = bus;
	printf(DEVICE_NAME ": monitoring for ClaimAccelerometer\n");
	fflush(stdout);
	return 0;
}

/*
 * Drain the monitor connection.  Returns the sender of the last
 * ClaimAccelerometer seen this round (or NULL), copying it into sender.  A
 * fatal bus error invalidates the monitor so the caller can restart it.
 */
static const char *drain_claim_monitor(char sender[64])
{
	sd_bus_message *m = NULL;
	bool have_sender = false;
	int r;

	if (!claim_monitor)
		return NULL;

	while ((r = sd_bus_process(claim_monitor, &m)) > 0) {
		if (sd_bus_message_is_method_call(m, ACCEL_INTERFACE,
						  "ClaimAccelerometer")) {
			const char *s = sd_bus_message_get_sender(m);

			if (s != NULL) {
				(void)snprintf(sender, 64, "%s", s);
				have_sender = true;
			}
			printf(DEVICE_NAME ": ClaimAccelerometer from %s\n",
			       s ? s : "?");
			fflush(stdout);
		}
		sd_bus_message_unref(m);
		m = NULL;
	}

	if (r < 0) {
		fprintf(stderr, DEVICE_NAME ": claim monitor lost: %s\n",
			strerror(-r));
		sd_bus_unref(claim_monitor);
		claim_monitor = NULL;
	}

	return have_sender ? sender : NULL;
}

int main(int argc, char **argv)
{
	struct uinput_setup setup = {
		.id = {
			.bustype = BUS_HOST,
			.vendor = 0x2717,
			.product = 0x0001,
			.version = 1,
		},
	};
	struct sigaction action = {
		.sa_handler = handle_signal,
	};
	int fd;
	int status = EXIT_FAILURE;
	enum shell_state state = SHELL_NONE;
	bool enabled = false;
	bool waiting = false;
	char last_sender[64] = "";
	char sender[64];
	uint64_t wait_deadline = 0;
	uint64_t monitor_retry_at = 0;

	if (argc != 1) {
		fprintf(stderr, "usage: %s\n", argv[0]);
		return EXIT_FAILURE;
	}

	fd = open("/dev/uinput", O_WRONLY | O_NONBLOCK | O_CLOEXEC);
	if (fd < 0) {
		perror("open /dev/uinput");
		return EXIT_FAILURE;
	}

	if (ioctl(fd, UI_SET_EVBIT, EV_SW) < 0 ||
	    ioctl(fd, UI_SET_SWBIT, SW_TABLET_MODE) < 0) {
		perror("configure uinput tablet switch");
		goto out_close;
	}

	(void)snprintf(setup.name, sizeof(setup.name), "%s", DEVICE_NAME);
	if (ioctl(fd, UI_DEV_SETUP, &setup) < 0 || ioctl(fd, UI_DEV_CREATE) < 0) {
		perror("create uinput tablet switch");
		goto out_close;
	}

	/*
	 * Start in laptop mode.  Mutter gives native-portrait panels one initial
	 * accelerometer update before applying tablet-mode policy.  Advertising ON
	 * before that update makes Mutter inhibit the sensor immediately afterwards.
	 */
	if (set_tablet_mode(fd, false) < 0) {
		perror("initialize tablet mode switch");
		goto out_destroy;
	}

	printf(DEVICE_NAME ": SW_TABLET_MODE=OFF; waiting for a graphical shell\n");
	fflush(stdout);

	sigemptyset(&action.sa_mask);
	if (sigaction(SIGINT, &action, NULL) < 0 ||
	    sigaction(SIGTERM, &action, NULL) < 0) {
		perror("sigaction");
		goto out_destroy;
	}

	if (start_claim_monitor() < 0)
		monitor_retry_at = now_us() + MONITOR_RETRY_USEC;

	while (!stopping) {
		enum shell_state current = current_shell_state();
		const char *claimer;

		/*
		 * Restart the laptop -> tablet cycle whenever the active shell
		 * changes, e.g. when the user session replaces the greeter.
		 * Each Mutter instance needs its own OFF -> ON edge while the
		 * accelerometer is already present.
		 */
		if (current != state) {
			state = current;
			if (enabled) {
				if (set_tablet_mode(fd, false) < 0) {
					perror("disable tablet mode");
					goto out_destroy;
				}
				enabled = false;
				printf(DEVICE_NAME ": SW_TABLET_MODE=OFF; graphical shell changed\n");
				fflush(stdout);
			}
			waiting = (state != SHELL_NONE);
			if (waiting)
				wait_deadline = now_us() + CLAIM_TIMEOUT_USEC;
		}

		claimer = drain_claim_monitor(sender);

		if (waiting && claimer != NULL &&
		    strcmp(claimer, last_sender) != 0) {
			(void)snprintf(last_sender, sizeof(last_sender), "%s",
				       claimer);
			if (set_tablet_mode(fd, true) < 0) {
				perror("enable tablet mode");
				goto out_destroy;
			}
			enabled = true;
			waiting = false;
			printf(DEVICE_NAME ": SW_TABLET_MODE=ON (accelerometer claimed)\n");
			fflush(stdout);
		} else if (waiting && now_us() >= wait_deadline) {
			if (set_tablet_mode(fd, true) < 0) {
				perror("enable tablet mode");
				goto out_destroy;
			}
			enabled = true;
			waiting = false;
			printf(DEVICE_NAME ": SW_TABLET_MODE=ON (no claim seen, timeout)\n");
			fflush(stdout);
		}

		if (claim_monitor == NULL && now_us() >= monitor_retry_at) {
			(void)start_claim_monitor();
			monitor_retry_at = now_us() + MONITOR_RETRY_USEC;
		}

		if (claim_monitor != NULL)
			(void)sd_bus_wait(claim_monitor, POLL_USEC);
		else
			(void)sleep_us(POLL_USEC);
	}

	status = EXIT_SUCCESS;
	if (enabled && set_tablet_mode(fd, false) < 0)
		perror("disable tablet mode");

out_destroy:
	if (ioctl(fd, UI_DEV_DESTROY) < 0)
		perror("destroy uinput tablet switch");
	sd_bus_unref(claim_monitor);
out_close:
	close(fd);
	return status;
}

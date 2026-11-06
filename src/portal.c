// XDG Desktop Portal file chooser shim.
//
// The GUI asks for one folder. The portal call is asynchronous on the bus: it
// returns a request handle immediately and later emits org.freedesktop.portal.
// Request.Response. This shim waits for that signal on the predicted request
// path (the handle_token form the portal guarantees), then returns the chosen
// path. It is run by a child process from the GUI so the window stays live.
//
// Return values:
//   0  a folder was chosen
//   1  the user cancelled
//  -1  the portal is unavailable or failed
#include <stdio.h>
#include <string.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>

#ifndef MIAGENT_NO_PORTAL
#include <gio/gio.h>
#include <unistd.h>

typedef struct {
	GMainLoop *loop;
	char *out;
	size_t out_size;
	guint32 response;
	gboolean timed_out;
} Picker_State;

static void on_response(
	GDBusConnection *connection,
	const char *sender_name,
	const char *object_path,
	const char *interface_name,
	const char *signal_name,
	GVariant *parameters,
	gpointer user_data
) {
	(void)connection;
	(void)sender_name;
	(void)object_path;
	(void)interface_name;
	(void)signal_name;

	Picker_State *state = (Picker_State *)user_data;
	guint32 response = 2;
	GVariant *results = NULL;
	g_variant_get(parameters, "(u@a{sv})", &response, &results);
	state->response = response;

	if (response == 0 && results != NULL) {
		GVariant *uris = g_variant_lookup_value(results, "uris", G_VARIANT_TYPE_STRING_ARRAY);
		if (uris != NULL) {
			if (g_variant_n_children(uris) > 0) {
				const gchar *uri = NULL;
				g_variant_get_child(uris, 0, "&s", &uri);
				if (uri != NULL && state->out != NULL && state->out_size > 0) {
					GError *error = NULL;
					gchar *path = g_filename_from_uri(uri, NULL, &error);
					if (path != NULL) {
						if (strlen(path) < state->out_size) {
							g_strlcpy(state->out, path, state->out_size);
						}
						g_free(path);
					}
					if (error != NULL) g_error_free(error);
				}
			}
			g_variant_unref(uris);
		}
	}
	if (results != NULL) g_variant_unref(results);
	if (state->loop != NULL) g_main_loop_quit(state->loop);
}

static gboolean on_timeout(gpointer user_data) {
	Picker_State *state = (Picker_State *)user_data;
	state->timed_out = TRUE;
	if (state->loop != NULL) g_main_loop_quit(state->loop);
	return G_SOURCE_REMOVE;
}

// The portal derives the request path from the caller's unique bus name:
// strip the leading ':' and replace dots in the name with underscores.
static char *request_name_component(const char *unique_name) {
	GString *s = g_string_new(unique_name != NULL ? unique_name : "unknown");
	if (s->len > 0 && s->str[0] == ':') g_string_erase(s, 0, 1);
	for (guint i = 0; i < s->len; i += 1) {
		if (s->str[i] == '.') s->str[i] = '_';
	}
	return g_string_free(s, FALSE);
}

int mi_portal_pick_folder(const char *title, char *out, size_t out_size) {
	if (out != NULL && out_size > 0) out[0] = 0;

	GError *error = NULL;
	GDBusConnection *connection = g_bus_get_sync(G_BUS_TYPE_SESSION, NULL, &error);
	if (connection == NULL) {
		fprintf(stderr, "portal: cannot connect to the session bus: %s\n",
			error != NULL ? error->message : "unknown error");
		if (error != NULL) g_error_free(error);
		return -1;
	}

	const char *unique = g_dbus_connection_get_unique_name(connection);
	char *sender = request_name_component(unique);
	static gint request_counter = 0;
	gint counter = g_atomic_int_add(&request_counter, 1);
	char token[64];
	g_snprintf(token, sizeof(token), "miagent_%d_%d", (int)getpid(), counter);
	char *request_path = g_strdup_printf(
		"/org/freedesktop/portal/desktop/request/%s/%s", sender, token);
	g_free(sender);

	Picker_State state = {0};
	state.loop = g_main_loop_new(NULL, FALSE);
	state.out = out;
	state.out_size = out_size;
	state.response = 2;

	// Subscribe before calling OpenFile: the portal may use this predicted
	// handle path, and waiting until the call returns would race the signal.
	guint subscription = g_dbus_connection_signal_subscribe(
		connection,
		NULL,
		"org.freedesktop.portal.Request",
		"Response",
		request_path,
		NULL,
		G_DBUS_SIGNAL_FLAGS_NONE,
		on_response,
		&state,
		NULL);

	GVariantBuilder options;
	g_variant_builder_init(&options, G_VARIANT_TYPE_VARDICT);
	g_variant_builder_add(&options, "{sv}", "handle_token", g_variant_new_string(token));
	g_variant_builder_add(&options, "{sv}", "directory", g_variant_new_boolean(TRUE));
	g_variant_builder_add(&options, "{sv}", "multiple", g_variant_new_boolean(FALSE));
	g_variant_builder_add(&options, "{sv}", "modal", g_variant_new_boolean(TRUE));

	GVariant *reply = g_dbus_connection_call_sync(
		connection,
		"org.freedesktop.portal.Desktop",
		"/org/freedesktop/portal/desktop",
		"org.freedesktop.portal.FileChooser",
		"OpenFile",
		g_variant_new("(ssa{sv})", "", title != NULL ? title : "Choose a folder", &options),
		G_VARIANT_TYPE("(o)"),
		G_DBUS_CALL_FLAGS_NONE,
		-1,
		NULL,
		&error);
	if (reply == NULL) {
		fprintf(stderr, "portal: OpenFile failed: %s\n",
			error != NULL ? error->message : "unknown error");
		if (error != NULL) g_error_free(error);
		if (subscription != 0) g_dbus_connection_signal_unsubscribe(connection, subscription);
		g_main_loop_unref(state.loop);
		g_free(request_path);
		g_object_unref(connection);
		return -1;
	}

	// In case a portal implementation returns a different handle than the
	// predicted one, listen there too. The dialog cannot respond before the
	// user acts, so this second subscription has time to install.
	guint fallback_subscription = 0;
	const gchar *handle = NULL;
	g_variant_get(reply, "(&o)", &handle);
	if (handle != NULL && g_strcmp0(handle, request_path) != 0) {
		fallback_subscription = g_dbus_connection_signal_subscribe(
			connection,
			NULL,
			"org.freedesktop.portal.Request",
			"Response",
			handle,
			NULL,
			G_DBUS_SIGNAL_FLAGS_NONE,
			on_response,
			&state,
			NULL);
	}
	g_variant_unref(reply);

	guint timeout_id = g_timeout_add_seconds(600, on_timeout, &state);
	g_main_loop_run(state.loop);
	if (!state.timed_out && timeout_id != 0) g_source_remove(timeout_id);

	if (subscription != 0) g_dbus_connection_signal_unsubscribe(connection, subscription);
	if (fallback_subscription != 0) {
		g_dbus_connection_signal_unsubscribe(connection, fallback_subscription);
	}
	g_main_loop_unref(state.loop);
	g_free(request_path);
	g_object_unref(connection);

	if (state.timed_out) return -1;
	if (state.response == 0 && out != NULL && out_size > 0 && out[0] != 0) return 0;
	if (state.response == 1) return 1;
	return -1;
}

#else

int mi_portal_pick_folder(const char *title, char *out, size_t out_size) {
	(void)title;
	(void)out;
	(void)out_size;
	fprintf(stderr, "portal: file chooser support not built (gio-2.0 missing)\n");
	return -1;
}

#endif

// Open a URI with the user's default handler. This is intentionally a tiny
// shim: the GUI validates the scheme before calling it.
int mi_open_uri(const char *uri) {
  if (uri == NULL || uri[0] == 0) return -1;
#ifndef MIAGENT_NO_PORTAL
  GError *error = NULL;
  gboolean ok = g_app_info_launch_default_for_uri(uri, NULL, &error);
  if (!ok) {
    if (error != NULL) g_error_free(error);
    return -1;
  }
  return 0;
#else
  pid_t pid = fork();
  if (pid < 0) return -1;
  if (pid == 0) {
    execlp("xdg-open", "xdg-open", uri, (char *)NULL);
    _exit(127);
  }
  int status = 0;
  if (waitpid(pid, &status, 0) < 0) return -1;
  return (WIFEXITED(status) && WEXITSTATUS(status) == 0) ? 0 : -1;
#endif
}

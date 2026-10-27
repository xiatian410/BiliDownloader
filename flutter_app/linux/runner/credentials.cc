#include "credentials.h"

#include <libsecret/secret.h>
#include <cstring>

namespace {
// Async libsecret calls keep a locked/unavailable keyring off GTK's UI thread.
// Each operation is cancelled after four seconds, before Dart's five-second cap.
const SecretSchema* schema() {
  static const SecretSchema value = [] {
    SecretSchema s = {};
    s.name = "io.github.xiatian410.BiliDownloader";
    s.flags = SECRET_SCHEMA_NONE;
    s.attributes[0] = {"key", SECRET_SCHEMA_ATTRIBUTE_STRING};
    return s;
  }();
  return &value;
}

struct Request {
  FlMethodCall* call;
  GCancellable* cancel;
  guint timeout;
};

gboolean cancel_request(gpointer data) {
  auto* request = static_cast<Request*>(data);
  request->timeout = 0;
  g_cancellable_cancel(request->cancel);
  return G_SOURCE_REMOVE;
}

void complete(GObject*, GAsyncResult* result, gpointer data) {
  auto* request = static_cast<Request*>(data);
  g_autoptr(GError) error = nullptr;
  g_autoptr(FlValue) value = nullptr;
  const char* method = fl_method_call_get_name(request->call);
  if (strcmp(method, "read") == 0) {
    gchar* password = secret_password_lookup_finish(result, &error);
    value = password ? fl_value_new_string(password) : fl_value_new_null();
    secret_password_free(password);
  } else if (strcmp(method, "write") == 0) {
    secret_password_store_finish(result, &error);
  } else {
    secret_password_clear_finish(result, &error);
  }
  if (request->timeout) g_source_remove(request->timeout);
  if (error) {
    // Do not expose secrets or provider-specific details to the UI/logs.
    fl_method_call_respond_error(request->call, "secureStorageError",
                                 "System credential storage unavailable", nullptr, nullptr);
  } else {
    fl_method_call_respond_success(request->call, value, nullptr);
  }
  g_object_unref(request->cancel);
  g_object_unref(request->call);
  delete request;
}

void on_method(FlMethodChannel*, FlMethodCall* call, gpointer) {
  const char* method = fl_method_call_get_name(call);
  if (strcmp(method, "read") != 0 && strcmp(method, "write") != 0 &&
      strcmp(method, "delete") != 0) {
    fl_method_call_respond_not_implemented(call, nullptr);
    return;
  }
  FlValue* args = fl_method_call_get_args(call);
  if (strcmp(method, "write") == 0 && fl_value_get_type(args) != FL_VALUE_TYPE_STRING) {
    fl_method_call_respond_error(call, "invalidArguments", "Expected a string", nullptr, nullptr);
    return;
  }
  auto* request = new Request{FL_METHOD_CALL(g_object_ref(call)), g_cancellable_new(), 0};
  request->timeout = g_timeout_add(4000, cancel_request, request);
  if (strcmp(method, "read") == 0) {
    secret_password_lookup(schema(), request->cancel, complete, request,
                           "key", "bilibili.cookies.v2", nullptr);
  } else if (strcmp(method, "write") == 0) {
    secret_password_store(schema(), SECRET_COLLECTION_DEFAULT, "BiliDownloader session",
                          fl_value_get_string(args), request->cancel, complete, request,
                          "key", "bilibili.cookies.v2", nullptr);
  } else {
    secret_password_clear(schema(), request->cancel, complete, request,
                          "key", "bilibili.cookies.v2", nullptr);
  }
}
}  // namespace

void register_credentials_channel(FlView* view) {
  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  g_autoptr(FlMethodChannel) channel = fl_method_channel_new(
      fl_engine_get_binary_messenger(fl_view_get_engine(view)),
      "bili_downloader/credentials", FL_METHOD_CODEC(codec));
  fl_method_channel_set_method_call_handler(channel, on_method, nullptr, nullptr);
}

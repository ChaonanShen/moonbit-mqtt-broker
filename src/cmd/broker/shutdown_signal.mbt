///|
extern "C" fn install_shutdown_handlers() = "moonbit_mqtt_install_shutdown_handlers"

///|
extern "C" fn shutdown_requested_ffi() -> Int = "moonbit_mqtt_shutdown_requested"

///|
fn configure_shutdown_signals() -> Unit {
  // Global async cancellation cannot start new filesystem work reliably after
  // cancellation begins. Convert SIGTERM/SIGINT into a polled service-stop
  // request so the normal server return path can force and drain its snapshot.
  @signal.set_global_cancellation_signals([])
  install_shutdown_handlers()
}

///|
fn shutdown_requested() -> Bool {
  shutdown_requested_ffi() != 0
}

///|
#borrow(path)
extern "C" fn private_key_status_ffi(path : String, path_length : Int) -> Int = "moonbit_mqtt_private_key_status"

///|
fn private_key_status(path : String) -> Int {
  private_key_status_ffi(path, path.length())
}

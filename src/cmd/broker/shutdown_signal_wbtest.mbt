///|
extern "C" fn send_reload_signal_ffi() -> Int = "moonbit_mqtt_test_send_reload_signal"

///|
test "SIGHUP flag coalesces and take clears without shutdown" {
  install_reload_signal_handler()
  assert_false(take_reload_signal())
  assert_eq(send_reload_signal_ffi(), 0)
  assert_eq(send_reload_signal_ffi(), 0)
  assert_true(take_reload_signal())
  assert_false(take_reload_signal())
  assert_false(shutdown_requested())
}

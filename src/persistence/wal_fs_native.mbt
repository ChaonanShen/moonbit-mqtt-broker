///|
#borrow(path)
extern "C" fn truncate_regular_ffi(
  path : Bytes,
  path_length : Int,
  expected_size : Int64,
  retained_size : Int64,
) -> Int = "moonbit_mqtt_truncate_regular"

///|
/// Recovery-only tail trim. The caller must hold the data-directory lock and
/// must not have an open writer for this file. The native side validates that
/// the path is a regular file of the size observed during recovery, then syncs
/// the truncated file before returning success.
pub fn truncate_regular_tail(
  path : String,
  expected_size : Int64,
  retained_size : Int64,
) -> Result[Unit, PersistenceError] {
  let encoded = @utf8.encode(path)
  if truncate_regular_ffi(
      encoded,
      encoded.length(),
      expected_size,
      retained_size,
    ) ==
    0 {
    Ok(())
  } else {
    Err(FileSystem(operation="truncate-wal-tail", path~))
  }
}

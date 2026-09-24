///|
pub(all) enum CaptureError {
  BackendUnavailable
  InvalidInput
  Busy
  AllocationFailure
  UnsafeSource
  SourceChanged
  TooLarge
  IoFailure
  Cancelled
  CryptoFailure
  InvalidState
} derive(Eq, Debug)

///|
pub struct CaptureWorker {
  mut handle : Int64
}

///|
extern "C" fn ffi_create() -> Int64 = "moonbit_mqtt_capture_worker_create"

///|
#borrow(path)
extern "C" fn ffi_submit(
  handle : Int64,
  task_id : Int64,
  path : Bytes,
  path_length : Int,
  max_bytes : Int,
  private_file : Int,
) -> Int = "moonbit_mqtt_capture_worker_submit"

///|
#borrow(cert, key)
extern "C" fn ffi_submit_tls(
  handle : Int64,
  task_id : Int64,
  cert : Bytes,
  cert_length : Int,
  key : Bytes,
  key_length : Int,
) -> Int = "moonbit_mqtt_capture_worker_submit_tls"

///|
extern "C" fn ffi_take_tls_directory(handle : Int64, task_id : Int64) -> Int = "moonbit_mqtt_capture_worker_take_tls_directory"

///|
extern "C" fn ffi_cancel(handle : Int64, task_id : Int64) -> Int = "moonbit_mqtt_capture_worker_cancel"

///|
extern "C" fn ffi_poll(handle : Int64) -> Int64 = "moonbit_mqtt_capture_worker_poll"

///|
#borrow(digest)
extern "C" fn ffi_result_info(
  handle : Int64,
  task_id : Int64,
  digest : FixedArray[Byte],
  digest_length : Int,
) -> Int = "moonbit_mqtt_capture_worker_result_info"

///|
#borrow(output)
extern "C" fn ffi_copy_chunk(
  handle : Int64,
  task_id : Int64,
  offset : Int,
  output : FixedArray[Byte],
  capacity : Int,
) -> Int = "moonbit_mqtt_capture_worker_copy_chunk"

///|
extern "C" fn ffi_reap(handle : Int64, task_id : Int64) -> Int = "moonbit_mqtt_capture_worker_reap"

///|
extern "C" fn ffi_stop(handle : Int64) -> Int = "moonbit_mqtt_capture_worker_stop"

///|
extern "C" fn ffi_destroy(handle : Int64) -> Int = "moonbit_mqtt_capture_worker_destroy"

///|
pub fn CaptureWorker::new() -> Result[CaptureWorker, CaptureError] {
  let handle = ffi_create()
  if handle == 0L {
    Err(BackendUnavailable)
  } else {
    Ok({ handle, })
  }
}

///|
/// A submitted path is copied into native-owned memory before returning.
/// A cancelled task keeps its slot until its terminal result is reaped.
pub fn CaptureWorker::submit(
  self : CaptureWorker,
  task_id : Int64,
  path : String,
  max_bytes : Int,
  private_file? : Bool = false,
) -> Result[Unit, CaptureError] {
  let encoded = @utf8.encode(path)
  match
    ffi_submit(
      self.handle,
      task_id,
      encoded,
      encoded.length(),
      max_bytes,
      if private_file {
        1
      } else {
        0
      },
    ) {
    0 => Ok(())
    1 => Err(Busy)
    -2 => Err(AllocationFailure)
    _ => Err(InvalidInput)
  }
}

///|

///|
/// Cert and key are copied into native-owned buffers before returning.
pub fn CaptureWorker::submit_tls(
  self : CaptureWorker,
  task_id : Int64,
  cert : Bytes,
  key : Bytes,
) -> Result[Unit, CaptureError] {
  match
    ffi_submit_tls(self.handle, task_id, cert, cert.length(), key, key.length()) {
    0 => Ok(())
    1 => Err(Busy)
    -2 => Err(AllocationFailure)
    _ => Err(InvalidInput)
  }
}

///|
pub fn CaptureWorker::take_tls_directory(
  self : CaptureWorker,
  task_id : Int64,
) -> Result[String, CaptureError] {
  let (length, _) = match self.result_info(task_id) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  if length < 24 || length > 127 {
    return Err(InvalidState)
  }
  let chunk = match self.copy_chunk(task_id, 0) {
    Ok(value) if value.length() == length => value
    _ => return Err(InvalidState)
  }
  let path = @utf8.decode(chunk) catch { _ => return Err(InvalidState) }
  if !path.has_prefix("/tmp/moonbit-mqtt-tls-") ||
    path[21:].contains("/") ||
    ffi_take_tls_directory(self.handle, task_id) != 0 {
    return Err(InvalidState)
  }
  Ok(path)
}

///|
pub fn CaptureWorker::cancel(
  self : CaptureWorker,
  task_id : Int64,
) -> Result[Bool, CaptureError] {
  match ffi_cancel(self.handle, task_id) {
    0 => Ok(true)
    1 => Ok(false)
    _ => Err(InvalidState)
  }
}

///|
/// Returns a task ID only after its native worker has finished.
pub fn CaptureWorker::poll(self : CaptureWorker) -> Int64? {
  let id = ffi_poll(self.handle)
  if id > 0L {
    Some(id)
  } else {
    None
  }
}

///|
pub fn CaptureWorker::result_info(
  self : CaptureWorker,
  task_id : Int64,
) -> Result[(Int, Bytes), CaptureError] {
  let digest : FixedArray[Byte] = FixedArray::make(32, 0)
  let length = ffi_result_info(self.handle, task_id, digest, digest.length())
  if length < 0 {
    return Err(
      match length {
        -11 => UnsafeSource
        -12 => SourceChanged
        -13 => TooLarge
        -14 => IoFailure
        -15 => Cancelled
        -16 => CryptoFailure
        _ => InvalidState
      },
    )
  }
  let bytes : Array[Byte] = []
  for byte in digest {
    bytes.push(byte)
  }
  Ok((length, Bytes::from_array(bytes)))
}

///|
/// Copies at most 4096 bytes per call; the caller yields between chunks.
pub fn CaptureWorker::copy_chunk(
  self : CaptureWorker,
  task_id : Int64,
  offset : Int,
) -> Result[Bytes, CaptureError] {
  let output : FixedArray[Byte] = FixedArray::make(4096, 0)
  let count = ffi_copy_chunk(
    self.handle,
    task_id,
    offset,
    output,
    output.length(),
  )
  if count < 0 {
    return Err(InvalidState)
  }
  let bytes : Array[Byte] = []
  for index in 0..<count {
    bytes.push(output[index])
  }
  Ok(Bytes::from_array(bytes))
}

///|
pub fn CaptureWorker::reap(
  self : CaptureWorker,
  task_id : Int64,
) -> Result[Unit, CaptureError] {
  if ffi_reap(self.handle, task_id) == 0 {
    Ok(())
  } else {
    Err(InvalidState)
  }
}

///|
/// Stop is non-blocking. Poll or reap an in-flight task before destroy.
pub fn CaptureWorker::stop(self : CaptureWorker) -> Bool {
  ffi_stop(self.handle) == 1
}

///|
pub fn CaptureWorker::destroy(self : CaptureWorker) -> Bool {
  if self.handle == 0L {
    return true
  }
  if ffi_destroy(self.handle) == 0 {
    self.handle = 0L
    true
  } else {
    false
  }
}

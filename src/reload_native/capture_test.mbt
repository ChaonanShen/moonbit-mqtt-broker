///|
async fn wait_capture(worker : CaptureWorker) -> Int64 {
  for _ in 0..<1000 {
    if worker.poll() is Some(id) {
      return id
    }
    @async.sleep(1)
  }
  abort("native capture worker did not finish")
}

///|
async fn stop_capture(worker : CaptureWorker) -> Unit {
  for _ in 0..<1000 {
    if worker.stop() {
      assert_true(worker.destroy())
      return
    }
    @async.sleep(1)
  }
  abort("native capture worker did not stop")
}

///|
async test "capture worker hashes and copies a bounded file" {
  let root = @fs.tmpdir(prefix="mqtt-capture-worker-")
  let path = root + "/source"
  @fs.write_file(path, b"abc", create_mode=CreateNew, permission=0o600)
  let worker = CaptureWorker::new().unwrap()
  assert_eq(worker.submit(1L, path, 1048576), Ok(()))
  assert_eq(wait_capture(worker), 1L)
  let (length, digest) = worker.result_info(1L).unwrap()
  assert_eq(length, 3)
  assert_eq(
    digest,
    Bytes::from_array([
      0xba, 0x78, 0x16, 0xbf, 0x8f, 0x01, 0xcf, 0xea, 0x41, 0x41, 0x40, 0xde, 0x5d,
      0xae, 0x22, 0x23, 0xb0, 0x03, 0x61, 0xa3, 0x96, 0x17, 0x7a, 0x9c, 0xb4, 0x10,
      0xff, 0x61, 0xf2, 0x00, 0x15, 0xad,
    ]),
  )
  assert_eq(worker.copy_chunk(1L, 0), Ok(b"abc"))
  assert_eq(worker.copy_chunk(1L, 3), Ok(b""))
  assert_eq(worker.submit(2L, path, 1048576), Err(Busy))
  assert_eq(worker.reap(1L), Ok(()))
  @fs.remove(path)
  let payload : Array[Byte] = []
  for _ in 0..<5000 {
    payload.push(65)
  }
  @fs.write_file(
    path,
    Bytes::from_array(payload),
    create_mode=CreateNew,
    permission=0o600,
  )
  assert_eq(worker.submit(2L, path, 1048576), Ok(()))
  assert_eq(wait_capture(worker), 2L)
  assert_eq(worker.result_info(2L).unwrap().0, 5000)
  assert_eq(worker.copy_chunk(2L, 0).unwrap().length(), 4096)
  assert_eq(worker.copy_chunk(2L, 4096).unwrap().length(), 904)
  assert_eq(worker.reap(2L), Ok(()))
  stop_capture(worker)
  @fs.remove(path)
  @fs.rmdir(root)
}

///|
async test "capture worker rejects unsafe and oversized sources" {
  let root = @fs.tmpdir(prefix="mqtt-capture-reject-")
  let path = root + "/source"
  let link = root + "/link"
  @fs.write_file(path, b"abc", create_mode=CreateNew, permission=0o644)
  @fs.symlink(target="source", link)
  let worker = CaptureWorker::new().unwrap()
  assert_eq(worker.submit(1L, link, 1024), Ok(()))
  assert_eq(wait_capture(worker), 1L)
  assert_eq(worker.result_info(1L), Err(UnsafeSource))
  assert_eq(worker.reap(1L), Ok(()))
  assert_eq(worker.submit(2L, path, 1024, private_file=true), Ok(()))
  assert_eq(wait_capture(worker), 2L)
  assert_eq(worker.result_info(2L), Err(UnsafeSource))
  assert_eq(worker.reap(2L), Ok(()))
  assert_eq(worker.submit(3L, path, 2), Ok(()))
  assert_eq(wait_capture(worker), 3L)
  assert_eq(worker.result_info(3L), Err(TooLarge))
  assert_eq(worker.reap(3L), Ok(()))
  stop_capture(worker)
  @fs.remove(link)
  @fs.remove(path)
  @fs.rmdir(root)
}

///|
async test "TLS native worker owns private material until explicit transfer" {
  let worker = CaptureWorker::new().unwrap()
  assert_eq(worker.submit_tls(1L, b"certificate-v1", b"key-v1"), Ok(()))
  assert_eq(wait_capture(worker), 1L)
  let directory = worker.take_tls_directory(1L).unwrap()
  assert_eq(@fs.read_file(directory + "/cert.pem").text(), "certificate-v1")
  assert_eq(@fs.read_file(directory + "/key.pem").text(), "key-v1")
  assert_eq(worker.reap(1L), Ok(()))
  assert_true(@fs.exists(directory))
  @fs.remove(directory + "/cert.pem")
  @fs.remove(directory + "/key.pem")
  @fs.rmdir(directory)
  assert_eq(worker.submit_tls(2L, b"certificate-v2", b"key-v2"), Ok(()))
  assert_eq(wait_capture(worker), 2L)
  let (length, _) = worker.result_info(2L).unwrap()
  let unpublished = @utf8.decode(worker.copy_chunk(2L, 0).unwrap())
  assert_eq(unpublished.length(), length)
  assert_true(@fs.exists(unpublished))
  assert_eq(worker.reap(2L), Ok(()))
  assert_false(@fs.exists(unpublished))
  stop_capture(worker)
}

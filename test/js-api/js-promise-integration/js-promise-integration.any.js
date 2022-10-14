// META: global=jsshell
// META: script=/wasm/jsapi/wasm-module-builder.js

function ToPromising(wasm_export) {
  let sig = WebAssembly.Function.type(wasm_export);
  assert_true(sig.parameters.length > 0);
  assert_equals('externref', sig.parameters[0]);
  let wrapper_sig = {
    parameters: sig.parameters.slice(1),
    results: ['externref']
  };
  return new WebAssembly.Function(
      wrapper_sig, wasm_export, {promising: 'first'});
}

test(() => {
  let builder = new WasmModuleBuilder();
  let sig_i_ri = makeSig([kWasmAnyRef, kWasmI32], [kWasmI32]);
  let sig_v_ri = makeSig([kWasmAnyRef, kWasmI32], []);
  builder.addImport('m', 'import', sig_v_ri);
  builder.addFunction("export", sig_i_ri)
      .addBody([kExprLocalGet, 1]).exportFunc();
  builder.addFunction("void_export", kSig_v_r).addBody([]).exportFunc();
  function js_import(i) {}

  // Wrap the import, instantiate the module, and wrap the export.
  let import_wrapper = new WebAssembly.Function(
      {parameters: ['externref', 'i32'], results: []},
      js_import,
      {suspending: 'first'});
  let instance = builder.instantiate({'m': {'import': import_wrapper}});
  let export_wrapper = ToPromising(instance.exports.export);

  // Bad flag value.
  assert_throws(TypeError, () => new WebAssembly.Function(
      {parameters: ['externref', 'i32'], results: []},
      js_import,
      {suspending: 'foo'}));

  assert_throws(TypeError, () => new WebAssembly.Function(
      {parameters: ['i32'], results: ['externref']},
      instance.exports.export,
      {promising: 'foo'}));

  // Signature mismatch.
  assert_throws(TypeError, () => new WebAssembly.Function(
      {parameters: ['externref'], results: []},
      new WebAssembly.Function(
          {parameters: [], results: ['i32']}, js_import),
      {suspending: 'first'}));

  assert_throws(TypeError, () => new WebAssembly.Function(
      {parameters: ['externref', 'i32'], results: ['i32']},
      instance.exports.export,
      {promising: 'first'}));

  // Check the wrapper signatures.
  let export_sig = WebAssembly.Function.type(export_wrapper);
  assert_array_equals(['i32'], export_sig.parameters);
  assert_array_equals(['externref'], export_sig.results);

  let import_sig = WebAssembly.Function.type(import_wrapper);
  assert_array_equals(['externref', 'i32'], import_sig.parameters);
  assert_array_equals([], import_sig.results);

  let void_export_wrapper = ToPromising(instance.exports.void_export);
  let void_export_sig = WebAssembly.Function.type(void_export_wrapper);
  assert_array_equals([], void_export_sig.parameters);
  assert_array_equals(['externref'], void_export_sig.results);
}, "Test import and export type checking");

promise_test(async () => {
  let builder = new WasmModuleBuilder();
  import_index = builder.addImport('m', 'import', kSig_i_r);
  builder.addFunction("test", kSig_i_r)
      .addBody([
          kExprLocalGet, 0,
          kExprCallFunction, import_index, // suspend
      ]).exportFunc();
  let js_import = new WebAssembly.Function(
      {parameters: ['externref'], results: ['i32']},
      () => Promise.resolve(42),
      {suspending: 'first'});
  let instance = builder.instantiate({m: {import: js_import}});
  let wrapped_export = ToPromising(instance.exports.test);
  let export_promise = wrapped_export();
  assert_true(export_promise instanceof Promise);
  assert_equals(42, await export_promise);
}, "Suspend once");

promise_test(async () => {
  let builder = new WasmModuleBuilder();
  builder.addGlobal(kWasmI32, true).exportAs('g');
  import_index = builder.addImport('m', 'import', kSig_i_r);
  // void test() {
  //   for (i = 0; i < 5; ++i) {
  //     g = g + await import();
  //   }
  // }
  builder.addFunction("test", kSig_v_r)
      .addLocals({ i32_count: 1})
      .addBody([
          kExprI32Const, 5,
          kExprLocalSet, 1,
          kExprLoop, kWasmStmt,
            kExprLocalGet, 0,
            kExprCallFunction, import_index, // suspend
            kExprGlobalGet, 0,
            kExprI32Add,
            kExprGlobalSet, 0,
            kExprLocalGet, 1,
            kExprI32Const, 1,
            kExprI32Sub,
            kExprLocalTee, 1,
            kExprBrIf, 0,
          kExprEnd,
      ]).exportFunc();
  let i = 0;
  function js_import() {
    return Promise.resolve(++i);
  };
  let wasm_js_import = new WebAssembly.Function(
      {parameters: ['externref'], results: ['i32']},
      js_import,
      {suspending: 'first'});
  let instance = builder.instantiate({m: {import: wasm_js_import}});
  let wrapped_export = ToPromising(instance.exports.test);
  let export_promise = wrapped_export();
  assert_equals(0, instance.exports.g.value);
  assert_true(export_promise instanceof Promise);
  await export_promise;
  assert_equals(15, instance.exports.g.value);
}, "Suspend/resume in a loop");

test(() => {
  let builder = new WasmModuleBuilder();
  import_index = builder.addImport('m', 'import', kSig_i_r);
  builder.addFunction("test", kSig_i_r)
      .addBody([
          kExprLocalGet, 0,
          kExprCallFunction, import_index, // suspend
      ]).exportFunc();
  function js_import() {
    return 42
  };
  let wasm_js_import = new WebAssembly.Function(
      {parameters: ['externref'], results: ['i32']},
      js_import,
      {suspending: 'first'});
  let instance = builder.instantiate({m: {import: wasm_js_import}});
  let wrapped_export = ToPromising(instance.exports.test);
  assert_equals(42, wrapped_export());
}, "Do not suspend if the import's return value is not a Promise");

test(t => {
  let tag = new WebAssembly.Tag({parameters: []});
  let builder = new WasmModuleBuilder();
  import_index = builder.addImport('m', 'import', kSig_i_r);
  tag_index = builder.addImportedException('m', 'tag', kSig_v_v);
  builder.addFunction("test", kSig_i_r)
      .addBody([
          kExprLocalGet, 0,
          kExprCallFunction, import_index,
          kExprThrow, tag_index
      ]).exportFunc();
  function js_import() {
    return Promise.resolve();
  };
  let wasm_js_import = new WebAssembly.Function(
      {parameters: ['externref'], results: ['i32']},
      js_import,
      {suspending: 'first'});

  let instance = builder.instantiate({m: {import: wasm_js_import, tag: tag}});
  let wrapped_export = ToPromising(instance.exports.test);
  let export_promise = wrapped_export();
  assert_true(export_promise instanceof Promise);
  promise_rejects(t, new WebAssembly.Exception(tag, []), export_promise);
}, "Throw after the first suspension");

promise_test(async () => {
  let tag = new WebAssembly.Tag({parameters: ['i32']});
  let builder = new WasmModuleBuilder();
  import_index = builder.addImport('m', 'import', kSig_i_r);
  tag_index = builder.addImportedException('m', 'tag', kSig_v_i);
  builder.addFunction("test", kSig_i_r)
      .addBody([
          kExprTry, kWasmI32,
          kExprLocalGet, 0,
          kExprCallFunction, import_index,
          kExprCatch, tag_index,
          kExprEnd,
      ]).exportFunc();
  function js_import() {
    return Promise.reject(new WebAssembly.Exception(tag, [42]));
  };
  let wasm_js_import = new WebAssembly.Function(
      {parameters: ['externref'], results: ['i32']},
      js_import,
      {suspending: 'first'});

  let instance = builder.instantiate({m: {import: wasm_js_import, tag: tag}});
  let wrapped_export = ToPromising(instance.exports.test);
  let export_promise = wrapped_export();
  assert_true(export_promise instanceof Promise);
  assert_equals(42, await export_promise);
}, "Rejecting promise");

async function TestNestedSuspenders(suspend) {
  // Nest two suspenders. The call chain looks like:
  // outer (wasm) -> outer (js) -> inner (wasm) -> inner (js)
  // If 'suspend' is true, the inner JS function returns a Promise, which
  // suspends the inner wasm function, which returns a Promise, which suspends
  // the outer wasm function, which returns a Promise. The inner Promise
  // resolves first, which resumes the inner continuation. Then the outer
  // promise resolves which resumes the outer continuation.
  // If 'suspend' is false, the inner JS function returns a regular value and
  // no computation is suspended.
  let builder = new WasmModuleBuilder();
  inner_index = builder.addImport('m', 'inner', kSig_i_r);
  outer_index = builder.addImport('m', 'outer', kSig_i_r);
  builder.addFunction("outer", kSig_i_r)
      .addBody([
          kExprLocalGet, 0,
          kExprCallFunction, outer_index
      ]).exportFunc();
  builder.addFunction("inner", kSig_i_r)
      .addBody([
          kExprLocalGet, 0,
          kExprCallFunction, inner_index
      ]).exportFunc();

  let inner = new WebAssembly.Function(
      {parameters: ['externref'], results: ['i32']},
      () => suspend ? Promise.resolve(42) : 43,
      {suspending: 'first'});

  let export_inner;
  let outer = new WebAssembly.Function(
      {parameters: ['externref'], results: ['i32']},
      () => export_inner(),
      {suspending: 'first'});

  let instance = builder.instantiate({m: {inner, outer}});
  export_inner = ToPromising(instance.exports.inner);
  let export_outer = ToPromising(instance.exports.outer);
  let result = export_outer();
  if (suspend) {
    assert_true(result instanceof Promise);
    assert_equals(42, await result);
  } else {
    assert_equals(43, result);
  }
}

test(() => {
  TestNestedSuspenders(true);
}, "Test nested suspenders with suspension");

test(() => {
  TestNestedSuspenders(false);
}, "Test nested suspenders with no suspension");

test(() => {
  let builder = new WasmModuleBuilder();
  let import_index = builder.addImport('m', 'import', kSig_i_r);
  builder.addFunction("test", kSig_i_r)
      .addBody([
          kExprLocalGet, 0,
          kExprCallFunction, import_index, // suspend
      ]).exportFunc();
  builder.addFunction("return_suspender", kSig_r_r)
      .addBody([
          kExprLocalGet, 0
      ]).exportFunc();
  let js_import = new WebAssembly.Function(
      {parameters: ['externref'], results: ['i32']},
      () => Promise.resolve(42),
      {suspending: 'first'});
  let instance = builder.instantiate({m: {import: js_import}});
  let suspender = ToPromising(instance.exports.return_suspender)();
  for (s of [suspender, null, undefined, {}]) {
    assert_throws(WebAssembly.RuntimeError, () => instance.exports.test(s));
  }
}, "Call import with an invalid suspender");

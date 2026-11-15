"use strict";
(() => {
  var __create = Object.create;
  var __defProp = Object.defineProperty;
  var __getOwnPropDesc = Object.getOwnPropertyDescriptor;
  var __getOwnPropNames = Object.getOwnPropertyNames;
  var __getProtoOf = Object.getPrototypeOf;
  var __hasOwnProp = Object.prototype.hasOwnProperty;
  var __require = /* @__PURE__ */ ((x) => typeof require !== "undefined" ? require : typeof Proxy !== "undefined" ? new Proxy(x, {
    get: (a, b) => (typeof require !== "undefined" ? require : a)[b]
  }) : x)(function(x) {
    if (typeof require !== "undefined") return require.apply(this, arguments);
    throw Error('Dynamic require of "' + x + '" is not supported');
  });
  var __copyProps = (to, from, except, desc) => {
    if (from && typeof from === "object" || typeof from === "function") {
      for (let key of __getOwnPropNames(from))
        if (!__hasOwnProp.call(to, key) && key !== except)
          __defProp(to, key, { get: () => from[key], enumerable: !(desc = __getOwnPropDesc(from, key)) || desc.enumerable });
    }
    return to;
  };
  var __toESM = (mod, isNodeMode, target) => (target = mod != null ? __create(__getProtoOf(mod)) : {}, __copyProps(
    // If the importer is in node compatibility mode or this is not an ESM
    // file that has been converted to a CommonJS file using a Babel-
    // compatible transform (i.e. "__esModule" has not been set), then set
    // "default" to the CommonJS "module.exports" for node compatibility.
    isNodeMode || !mod || !mod.__esModule ? __defProp(target, "default", { value: mod, enumerable: true }) : target,
    mod
  ));

  // src/main/js/wasm-gc-runtime/runtime.ts
  var globalsCache = /* @__PURE__ */ new Map();
  var exceptionFrameRegex = /.+:wasm-function\[[0-9]+]:0x([0-9a-f]+).*/;
  function getGlobalName(name) {
    let result = globalsCache.get(name);
    if (typeof result === "undefined") {
      result = new Function("return " + name + ";");
      globalsCache.set(name, result);
    }
    return result();
  }
  function setGlobalName(name, value) {
    new Function("value", name + " = value;")(value);
  }
  function defaults(imports, userExports, stringBuiltins) {
    const context = {
      exports: null,
      userExports,
      stackDeobfuscator: null
    };
    if (!stringBuiltins) {
      stringImports(imports);
    }
    dateImports(imports);
    consoleImports(imports);
    coreImports(imports, context);
    asyncImports(imports);
    jsoImports(imports, context, stringBuiltins);
    imports.teavmMath = Math;
    return {
      supplyExports(exports) {
        context.exports = exports;
      },
      supplyStackDeobfuscator(deobfuscator) {
        context.stackDeobfuscator = deobfuscator;
      }
    };
  }
  var javaExceptionSymbol = /* @__PURE__ */ Symbol("javaException");
  var JavaError = class extends Error {
    #context;
    [javaExceptionSymbol];
    constructor(context, javaException) {
      super();
      this.#context = context;
      this[javaExceptionSymbol] = javaException;
      context.exports["teavm.setJsException"](javaException, this);
    }
    get message() {
      const exceptionMessage = this.#context.exports["teavm.exceptionMessage"];
      const stringToJs = this.#context.exports["teavm.stringToJs"];
      if (typeof exceptionMessage === "function" && typeof stringToJs === "function") {
        const msg = exceptionMessage(this[javaExceptionSymbol]);
        if (msg != null) {
          return stringToJs(msg);
        }
      }
      return "(could not fetch message)";
    }
  };
  function stringImports(imports) {
    imports["wasm:js-string"] = {
      fromCharCode: (code) => String.fromCharCode(code),
      fromCharCodeArray: () => {
        throw new Error("Not supported");
      },
      intoCharCodeArray: () => {
        throw new Error("Not supported");
      },
      concat: (first, second) => first + second,
      charCodeAt: (string, index) => string.charCodeAt(index),
      length: (s) => s.length,
      substring: (s, start, end) => s.substring(start, end)
    };
  }
  function dateImports(imports) {
    imports.teavmDate = {
      currentTimeMillis: () => (/* @__PURE__ */ new Date()).getTime(),
      dateToString: (timestamp) => new Date(timestamp).toString(),
      getYear: (timestamp) => new Date(timestamp).getFullYear(),
      setYear(timestamp, year) {
        const date = new Date(timestamp);
        date.setFullYear(year);
        return date.getTime();
      },
      getMonth: (timestamp) => new Date(timestamp).getMonth(),
      setMonth(timestamp, month) {
        const date = new Date(timestamp);
        date.setMonth(month);
        return date.getTime();
      },
      getDate: (timestamp) => new Date(timestamp).getDate(),
      setDate(timestamp, value) {
        const date = new Date(timestamp);
        date.setDate(value);
        return date.getTime();
      },
      create: (year, month, date, hrs, min, sec) => new Date(year, month, date, hrs, min, sec).getTime(),
      createFromUTC: (year, month, date, hrs, min, sec) => Date.UTC(year, month, date, hrs, min, sec)
    };
  }
  function consoleImports(imports) {
    let stderr = "";
    let stdout = "";
    imports.teavmConsole = {
      putcharStderr(c) {
        if (c === 10) {
          console.error(stderr);
          stderr = "";
        } else {
          stderr += String.fromCharCode(c);
        }
      },
      putcharStdout(c) {
        if (c === 10) {
          console.log(stdout);
          stdout = "";
        } else {
          stdout += String.fromCharCode(c);
        }
      }
    };
  }
  function align(address, shift) {
    return (address - 1 >> shift) + 1 << shift;
  }
  async function linkImports(imports, options, module, emscriptenModules) {
    const memoryOptions = options.memory ?? {};
    const memDefaults = module ? getMemoryDefaults(module) : {};
    let memoryInstance = memoryOptions.external;
    const stackSize = options.stack ?? 2 * (1 << 20);
    let ptr = memDefaults.dataSize ?? 0;
    let tablePtr = 0;
    for (const emscriptenModule of emscriptenModules) {
      const dylinkInfo = extractDylinkInfo(emscriptenModule.wasmModule);
      const memSize = dylinkInfo.memorySize ?? 0;
      const memAlign = dylinkInfo.memoryAlignment ?? 1;
      const tableSize = dylinkInfo.tableSize ?? 0;
      const tableAlign = dylinkInfo.tableAlignment ?? 1;
      if (memSize > 0) {
        ptr = align(ptr, memAlign);
        emscriptenModule.memoryOffset = ptr;
        ptr += memSize;
      }
      if (tableSize > 0) {
        tablePtr = align(tablePtr, tableAlign);
        emscriptenModule.tableOffset = tablePtr;
        tablePtr += tableSize;
      }
    }
    let stackPtr = -1;
    let stackLow = -1;
    let stackHigh = -1;
    if (emscriptenModules.length > 0) {
      ptr = align(ptr, 4);
      stackPtr = ptr;
      stackLow = ptr;
      ptr += stackSize;
      ptr = align(ptr, 4);
      stackHigh = ptr;
    }
    let maxSize = memoryOptions.maxSize;
    ptr = align(ptr, 8);
    const heapOffset = ptr;
    if (!memoryInstance) {
      const minSize = memDefaults.min ?? 0;
      ptr += minSize;
      ptr = Math.max(ptr, memoryOptions.minSize ?? 0);
      const shared = memoryOptions.shared ?? memDefaults.shared ?? false;
      maxSize ??= (1 << 31) - 1 | 0;
      const initialPages = Math.max(minSize, emscriptenModules.length === 0 ? 1 : 256);
      const maxPages = shared ? initialPages : (maxSize - 1 >> 16) + 1;
      memoryInstance = new WebAssembly.Memory({
        shared,
        initial: initialPages,
        maximum: maxPages
      });
    }
    const tableInstance = tablePtr > 0 ? new WebAssembly.Table({ initial: tablePtr, element: "anyfunc" }) : null;
    imports.env = { memory: memoryInstance };
    imports.teavmMemory = {
      linearMemory() {
        return memoryInstance.buffer;
      },
      notifyHeapResized: memoryOptions.onResize ?? function() {
      },
      heapOffset: new WebAssembly.Global({ value: "i32", mutable: false }, heapOffset),
      maxSize: new WebAssembly.Global({ value: "i32", mutable: false }, maxSize)
    };
    const allocator = { malloc: null, free: null, realloc: null };
    await Promise.all(emscriptenModules.map(async ({ name, wasmModule, jsLoader, tableOffset, memoryOffset }) => {
      const loadedEmscripten = await jsLoader({
        wasmMemory: memoryInstance,
        instantiateWasm(emscriptenImports, successCallback) {
          emscriptenImports.env = {
            memory: memoryInstance,
            malloc: (size) => allocator.malloc(size),
            free: (p) => allocator.free(p),
            realloc: (p, newSize) => allocator.realloc(p, newSize),
            __indirect_function_table: tableInstance,
            __memory_base: new WebAssembly.Global({ value: "i32", mutable: false }, memoryOffset ?? 0),
            __table_base: new WebAssembly.Global({ value: "i32", mutable: false }, tableOffset ?? 0),
            __stack_pointer: new WebAssembly.Global({ value: "i32", mutable: true }, stackPtr)
          };
          emscriptenImports["GOT.mem"] = {
            __stack_low: new WebAssembly.Global({ value: "i32", mutable: true }, stackLow),
            __stack_high: new WebAssembly.Global({ value: "i32", mutable: true }, stackHigh)
          };
          WebAssembly.instantiate(wasmModule, emscriptenImports).then(successCallback);
        }
      });
      const importObj = {};
      for (const { name: exportName, kind: exportKind } of WebAssembly.Module.exports(wasmModule)) {
        if (exportKind === "function") {
          const fn = loadedEmscripten["_" + exportName];
          if (typeof fn === "function") {
            importObj[exportName] = fn;
          }
        }
      }
      imports[name] = importObj;
    }));
    return allocator;
  }
  var ReaderHelper = class {
    ptr = 0;
    array;
    constructor(array) {
      this.array = array;
    }
    readVarInt() {
      let result = 0;
      let shift = 0;
      while (true) {
        const b = this.array[this.ptr++];
        result |= (b & 127) << shift;
        if ((b & 128) === 0) {
          return result;
        }
        shift += 7;
      }
    }
  };
  function extractDylinkInfo(module) {
    const sections = WebAssembly.Module.customSections(module, "dylink.0");
    if (sections.length !== 1) {
      return {};
    }
    const section = new ReaderHelper(new Int8Array(sections[0]));
    const dylinkInfo = {};
    while (section.ptr < section.array.length) {
      const subsectionType = section.array[section.ptr++];
      const nextSubsection = section.ptr + section.readVarInt();
      switch (subsectionType) {
        case 1:
          dylinkInfo.memorySize = section.readVarInt();
          dylinkInfo.memoryAlignment = section.readVarInt();
          dylinkInfo.tableSize = section.readVarInt();
          dylinkInfo.tableAlignment = section.readVarInt();
          break;
      }
      section.ptr = nextSubsection;
    }
    return dylinkInfo;
  }
  function coreImports(imports, context) {
    const finalizationRegistry = new FinalizationRegistry((heldValue) => {
      const report = context.exports["teavm.reportGarbageCollectedValue"];
      if (typeof report !== "undefined") {
        report(heldValue.queue, heldValue.ref);
      }
    });
    const stringFinalizationRegistry = new FinalizationRegistry((heldValue) => {
      const report = context.exports?.["teavm.reportGarbageCollectedString"];
      if (typeof report === "function") {
        report(heldValue);
      }
    });
    imports.teavm = {
      createWeakRef(value, ref, queue) {
        if (queue !== null) {
          finalizationRegistry.register(value, { ref, queue });
        }
        return new WeakRef(value);
      },
      deref: (weakRef) => {
        const result = weakRef.deref();
        return result !== void 0 ? result : null;
      },
      createStringWeakRef(value, heldValue) {
        stringFinalizationRegistry.register(value, heldValue);
        return new WeakRef(value);
      },
      stringDeref: (weakRef) => weakRef.deref(),
      takeStackTrace(exceptionClassName) {
        const stack = new Error().stack ?? "";
        const addresses = [];
        for (const line of stack.split("\n")) {
          const match = exceptionFrameRegex.exec(line);
          if (match !== null && match.length >= 2) {
            addresses.push(parseInt(match[1], 16));
          }
        }
        return {
          getStack() {
            let result;
            if (context.stackDeobfuscator) {
              try {
                result = context.stackDeobfuscator(addresses);
              } catch (e) {
                console.warn("Could not deobfuscate stack", e);
              }
            }
            if (!result) {
              result = addresses.map((address) => ({
                className: "java.lang.Throwable$FakeClass",
                method: "fakeMethod",
                file: "Throwable.java",
                line: address
              }));
            } else if (exceptionClassName !== null) {
              if (result.length > 0 && result[0].className === "java.lang.Throwable" && result[0].method === "fillInStackTrace") {
                result.shift();
              }
              let foundIndex = -1;
              for (let i = 0; i < result.length; ++i) {
                if (result[i].method !== "<init>") {
                  break;
                }
                if (result[i].className === exceptionClassName) {
                  foundIndex = i + 1;
                  break;
                }
              }
              if (foundIndex >= 0) {
                result.splice(0, foundIndex);
              }
            }
            return result;
          }
        };
      },
      decorateException(javaException) {
        new JavaError(context, javaException);
      }
    };
  }
  function asyncImports(imports) {
    imports.teavmAsync = {
      offer(instance, fn, time) {
        const dt = Math.max(0, time - Date.now());
        return setTimeout(() => {
          fn(instance);
        }, dt);
      },
      kill(id) {
        clearTimeout(id);
      }
    };
  }
  function getMemoryDefaults(module) {
    const sections = WebAssembly.Module.customSections(module, "teavm.memoryRequirements");
    if (sections.length !== 1) {
      return {};
    }
    return JSON.parse(new TextDecoder().decode(sections[0]));
  }
  function jsoImports(imports, context, stringBuiltins) {
    const javaObjectSymbol = /* @__PURE__ */ Symbol("javaObject");
    const functionsSymbol = /* @__PURE__ */ Symbol("functions");
    const functionOriginSymbol = /* @__PURE__ */ Symbol("functionOrigin");
    const wrapperCallMarkerSymbol = /* @__PURE__ */ Symbol("wrapperCallMarker");
    const jsWrappers = /* @__PURE__ */ new WeakMap();
    const javaWrappers = /* @__PURE__ */ new WeakMap();
    const primitiveWrappers = /* @__PURE__ */ new Map();
    const primitiveFinalization = new FinalizationRegistry((token) => primitiveWrappers.delete(token));
    const hashCodes = /* @__PURE__ */ new WeakMap();
    let lastHashCode = 2463534242;
    const nextHashCode = () => {
      let x = lastHashCode;
      x ^= x << 13;
      x ^= x >>> 17;
      x ^= x << 5;
      lastHashCode = x;
      return x;
    };
    function identity(value) {
      return value;
    }
    function sanitizeName(str) {
      let result = "";
      const firstChar = str.charAt(0);
      result += isIdentifierStart(firstChar) ? firstChar : "_";
      for (let i = 1; i < str.length; ++i) {
        const c = str.charAt(i);
        result += isIdentifierPart(c) ? c : "_";
      }
      return result;
    }
    function isIdentifierStart(s) {
      return s >= "A" && s <= "Z" || s >= "a" && s <= "z" || s === "_" || s === "$";
    }
    function isIdentifierPart(s) {
      return isIdentifierStart(s) || s >= "0" && s <= "9";
    }
    function setProperty(obj, prop, value) {
      if (obj === null) {
        setGlobalName(prop, value);
      } else {
        obj[prop] = value;
      }
    }
    function javaExceptionToJs(e) {
      if (e instanceof WebAssembly.Exception) {
        const tag = context.exports["teavm.javaException"];
        const getJsException = context.exports["teavm.getJsException"];
        if (e.is(tag)) {
          const javaException = e.getArg(tag, 0);
          const extracted = extractException(javaException);
          if (extracted !== null) {
            return extracted;
          }
          let wrapper = getJsException(javaException);
          if (typeof wrapper === "undefined") {
            wrapper = new JavaError(context, javaException);
          }
          return wrapper;
        }
      }
      return e;
    }
    function jsExceptionAsJava(e) {
      if (javaExceptionSymbol in e) {
        return e[javaExceptionSymbol];
      } else {
        return context.exports["teavm.js.wrapException"](e);
      }
    }
    function rethrowJsAsJava(e) {
      context.exports["teavm.js.throwException"](jsExceptionAsJava(e));
      throw e;
    }
    function extractException(e) {
      return context.exports["teavm.js.extractException"](e);
    }
    function rethrowJavaAsJs(e) {
      throw javaExceptionToJs(e);
    }
    function getProperty(obj, prop) {
      try {
        return obj !== null ? obj[prop] : getGlobalName(prop);
      } catch (e) {
        rethrowJsAsJava(e);
      }
    }
    function defineFunction(fn, vararg) {
      const params = [];
      const paramsForString = [];
      for (let i = 0; i < fn.length; ++i) {
        const name = "p" + i;
        params.push(name);
        paramsForString.push(name);
      }
      if (vararg) {
        const last = paramsForString.length - 1;
        paramsForString[last] = "..." + paramsForString[last];
      }
      const paramsAsString = paramsForString.join(", ");
      return new Function(
        "rethrowJavaAsJs",
        "fn",
        `return function(${paramsAsString}) {
    try {
        return fn(${params.join(", ")});
    } catch (e) {
        rethrowJavaAsJs(e);
    }
};`
      )(rethrowJavaAsJs, fn);
    }
    function renameConstructor(name, c) {
      return new Function(
        "constructor",
        `return function ${name}(marker, javaObject) {
    return constructor.call(this, marker, javaObject);
}
`
      )(c);
    }
    imports.teavmJso = {
      stringBuiltinsSupported: () => stringBuiltins,
      isUndefined: (o) => typeof o === "undefined",
      emptyArray: () => [],
      appendToArray: (array, e) => array.push(e),
      unwrapBoolean: (value) => value ? 1 : 0,
      wrapBoolean: (value) => !!value,
      getProperty,
      setProperty,
      setPropertyPure: setProperty,
      global(name) {
        try {
          return getGlobalName(name);
        } catch (e) {
          rethrowJsAsJava(e);
        }
      },
      createClass(name, parent, constructor) {
        name = sanitizeName(name ?? "JavaObject");
        let action;
        const fn = renameConstructor(name, function javajava(marker, javaObject) {
          if (marker === wrapperCallMarkerSymbol) {
            action.call(this, javaObject);
          } else if (constructor === null) {
            throw new Error("This class can't be instantiated directly");
          } else {
            try {
              return constructor.apply(null, arguments);
            } catch (e) {
              rethrowJavaAsJs(e);
            }
          }
        });
        if (parent === null) {
          action = function(javaObject) {
            this[javaObjectSymbol] = javaObject;
            this[functionsSymbol] = null;
          };
        } else {
          action = function(javaObject) {
            parent.call(this, javaObject);
          };
        }
        fn.prototype = Object.create(parent ? parent.prototype : Object.prototype);
        fn.prototype.constructor = fn;
        const boundFn = renameConstructor(name, function(javaObject) {
          return fn.call(this, wrapperCallMarkerSymbol, javaObject);
        });
        boundFn[wrapperCallMarkerSymbol] = fn;
        boundFn.prototype = fn.prototype;
        return boundFn;
      },
      exportClass(cls) {
        return cls[wrapperCallMarkerSymbol];
      },
      defineMethod(cls, name, fn, vararg) {
        const params = [];
        const paramsForString = [];
        for (let i = 1; i < fn.length; ++i) {
          const p = "p" + i;
          params.push(p);
          paramsForString.push(p);
        }
        if (vararg) {
          const last = paramsForString.length - 1;
          paramsForString[last] = "..." + paramsForString[last];
        }
        const paramsAsString = paramsForString.join(", ");
        cls.prototype[name] = new Function(
          "rethrowJavaAsJs",
          "fn",
          `return function(${paramsAsString}) {
    try {
        return fn(${["this", ...params].join(", ")});
    } catch (e) {
        rethrowJavaAsJs(e);
    }
};`
        )(rethrowJavaAsJs, fn);
      },
      defineStaticMethod(cls, name, fn, vararg) {
        cls[name] = defineFunction(fn, vararg);
      },
      defineFunction,
      defineProperty(cls, name, getFn, setFn) {
        const descriptor = {
          get() {
            try {
              return getFn(this);
            } catch (e) {
              rethrowJavaAsJs(e);
            }
          }
        };
        if (setFn !== null) {
          descriptor.set = function(value) {
            try {
              setFn(this, value);
            } catch (e) {
              rethrowJavaAsJs(e);
            }
          };
        }
        Object.defineProperty(cls.prototype, name, descriptor);
      },
      defineStaticProperty(cls, name, getFn, setFn) {
        const descriptor = {
          get() {
            try {
              return getFn();
            } catch (e) {
              rethrowJavaAsJs(e);
            }
          }
        };
        if (setFn !== null) {
          descriptor.set = function(value) {
            try {
              setFn(value);
            } catch (e) {
              rethrowJavaAsJs(e);
            }
          };
        }
        Object.defineProperty(cls, name, descriptor);
      },
      javaObjectToJS(instance, cls) {
        if (instance === null) {
          return null;
        }
        const existing = jsWrappers.get(instance);
        if (typeof existing != "undefined") {
          const result = existing.deref();
          if (typeof result !== "undefined") {
            return result;
          }
        }
        const obj = new cls(instance);
        jsWrappers.set(instance, new WeakRef(obj));
        return obj;
      },
      unwrapJavaObject(instance) {
        return instance[javaObjectSymbol];
      },
      asFunction(instance, propertyName) {
        if (instance === null || instance === void 0) {
          return null;
        }
        let functions = instance[functionsSymbol];
        if (functions === null) {
          functions = /* @__PURE__ */ Object.create(null);
          instance[functionsSymbol] = functions;
        }
        let result = functions[propertyName];
        if (typeof result !== "function") {
          result = function() {
            return instance[propertyName].apply(instance, arguments);
          };
          result[functionOriginSymbol] = instance;
          functions[propertyName] = result;
        }
        return result;
      },
      functionAsObject(fn, property) {
        if (fn === null || fn === void 0) {
          return null;
        }
        const origin = fn[functionOriginSymbol];
        if (typeof origin !== "undefined") {
          const functions = origin[functionsSymbol];
          if (functions !== void 0 && functions[property] === fn) {
            return origin;
          }
        }
        return {
          [property]: function(...args) {
            try {
              return fn(...args);
            } catch (e) {
              rethrowJavaAsJs(e);
            }
          }
        };
      },
      wrapObject(obj) {
        if (obj === null) {
          return null;
        }
        if (typeof obj === "object" || typeof obj === "function" || typeof obj === "symbol") {
          const asRecord = obj;
          let result = asRecord[javaObjectSymbol];
          if (typeof result === "object") {
            return result;
          }
          result = javaWrappers.get(obj)?.deref();
          if (result !== void 0) {
            return result;
          }
          result = context.exports["teavm.jso.createWrapper"](obj);
          javaWrappers.set(obj, new WeakRef(result));
          return result;
        } else {
          let result = primitiveWrappers.get(obj)?.deref();
          if (result !== void 0) {
            return result;
          }
          result = context.exports["teavm.jso.createWrapper"](obj);
          primitiveWrappers.set(obj, new WeakRef(result));
          primitiveFinalization.register(result, obj);
          return result;
        }
      },
      isPrimitive: (value, type) => typeof value === type || value === null,
      instanceOf: (value, type) => value instanceof type,
      instanceOfOrNull: (value, type) => value === null || value instanceof type,
      sameRef: (a, b) => a === b,
      hashCode: (obj) => {
        if (typeof obj === "object" || typeof obj === "function" || typeof obj === "symbol") {
          let code = hashCodes.get(obj);
          if (typeof code === "number") {
            return code;
          }
          code = nextHashCode();
          hashCodes.set(obj, code);
          return code;
        } else if (typeof obj === "number") {
          return obj | 0;
        } else if (typeof obj === "bigint") {
          return Number(BigInt.asIntN(32, obj));
        } else if (typeof obj === "boolean") {
          return obj ? 1 : 0;
        } else {
          return 0;
        }
      },
      apply: (instance, method, args) => {
        try {
          if (instance === null) {
            const fn = getGlobalName(method);
            return fn(...args);
          } else {
            return instance[method](...args);
          }
        } catch (e) {
          rethrowJsAsJava(e);
        }
      },
      concatArray: (a, b) => [...a, ...b],
      getJavaException: (e) => e[javaExceptionSymbol],
      getJSException: (e) => {
        const getJsException = context.exports["teavm.getJsException"];
        return getJsException(e);
      },
      jsExports: () => context.userExports
    };
    for (const name of [
      "wrapByte",
      "wrapShort",
      "wrapChar",
      "wrapInt",
      "wrapLong",
      "wrapFloat",
      "wrapDouble",
      "unwrapByte",
      "unwrapShort",
      "unwrapChar",
      "unwrapInt",
      "unwrapLong",
      "unwrapFloat",
      "unwrapDouble"
    ]) {
      imports.teavmJso[name] = identity;
    }
    function wrapCallFromJavaToJs(call) {
      try {
        return call();
      } catch (e) {
        rethrowJsAsJava(e);
      }
    }
    const argumentList = [];
    for (let i = 0; i < 32; ++i) {
      const args = argumentList.length === 0 ? "" : argumentList.join(", ");
      const argsAndBody = [...argumentList, "body"].join(", ");
      imports.teavmJso["createFunction" + i] = new Function(
        "wrapCallFromJavaToJs",
        ...argumentList,
        "body",
        `return new Function('wrapCallFromJavaToJs', ${argsAndBody}).bind(this, wrapCallFromJavaToJs);`
      ).bind(null, wrapCallFromJavaToJs);
      imports.teavmJso["bindFunction" + i] = (f, ...bindArgs) => f.bind(null, ...bindArgs);
      imports.teavmJso["callFunction" + i] = new Function(
        "rethrowJsAsJava",
        "fn",
        ...argumentList,
        `try {
    return fn(${args});
} catch (e) {
    rethrowJsAsJava(e);
}`
      ).bind(null, rethrowJsAsJava);
      imports.teavmJso["callMethod" + i] = new Function(
        "rethrowJsAsJava",
        "getGlobalName",
        "instance",
        "method",
        ...argumentList,
        `try {
    return instance !== null
        ? instance[method](${args})
        : getGlobalName(method)(${args});
} catch (e) {
    rethrowJsAsJava(e);
}`
      ).bind(null, rethrowJsAsJava, getGlobalName);
      imports.teavmJso["construct" + i] = new Function(
        "rethrowJsAsJava",
        "constructor",
        ...argumentList,
        `try {
    return new constructor(${args});
} catch (e) {
    rethrowJsAsJava(e);
}`
      ).bind(null, rethrowJsAsJava);
      imports.teavmJso["arrayOf" + i] = new Function(
        ...argumentList,
        "return [" + args + "]"
      );
      argumentList.push("p" + (i + 1));
    }
  }
  function wrapImport(importObj) {
    return new Proxy(importObj, {
      get(target, prop) {
        const result = target[prop];
        return new WebAssembly.Global({ value: "externref", mutable: false }, result);
      }
    });
  }
  async function wrapImports(wasmModule, imports) {
    const promises = [];
    const propertiesToAdd = {};
    for (const { module, name } of extractImports(wasmModule)) {
      if (module in imports) {
        continue;
      }
      let names = propertiesToAdd[module];
      if (names === void 0) {
        const namesByModule = [];
        names = namesByModule;
        propertiesToAdd[module] = names;
        promises.push((async () => {
          const moduleInstance = await import(module);
          const importsByModule = {};
          for (const n of namesByModule) {
            const importedName = n === "__self__" ? moduleInstance : moduleInstance[n];
            importsByModule[n] = new WebAssembly.Global(
              { value: "externref", mutable: false },
              importedName
            );
          }
          imports[module] = importsByModule;
        })());
      }
      names.push(name);
    }
    if (promises.length === 0) {
      return;
    }
    await Promise.all(promises);
  }
  function extractImports(module) {
    const sections = WebAssembly.Module.customSections(module, "teavm.imports");
    if (sections.length !== 1) {
      return WebAssembly.Module.imports(module).filter((importDecl) => importDecl.kind === "global");
    }
    return JSON.parse(new TextDecoder().decode(sections[0]));
  }
  async function load(src, options) {
    if (!options) {
      options = {};
    }
    const isNodeJs = options.nodejs || typeof process !== "undefined";
    const emscriptenModulePaths = options.emscriptenModules ?? {};
    const deobfuscatorOptions = options.stackDeobfuscator ?? {};
    const debugInfoLocation = deobfuscatorOptions.infoLocation ?? "auto";
    const compilationPromise = compileModule(src, isNodeJs);
    const [deobfuscatorFactory, module, debugInfo, emscriptenModules] = await Promise.all([
      deobfuscatorOptions.enabled ? getDeobfuscator(src, deobfuscatorOptions, isNodeJs) : Promise.resolve(null),
      compilationPromise,
      fetchExternalDebugInfo(src, debugInfoLocation, deobfuscatorOptions, isNodeJs),
      loadEmscriptenModules(emscriptenModulePaths, isNodeJs)
    ]);
    const importObj = {};
    const userExports = {};
    const defaultsResult = defaults(importObj, userExports, await hasStringBuiltins());
    const allocator = await linkImports(importObj, options, module, emscriptenModules);
    if (typeof options.installImports !== "undefined") {
      options.installImports(importObj);
    }
    if (!options.noAutoImports) {
      await wrapImports(module, importObj);
    }
    const instance = await WebAssembly.instantiate(module, importObj);
    allocator.malloc = instance.exports["teavm.malloc"];
    allocator.free = instance.exports["teavm.free"];
    allocator.realloc = instance.exports["teavm.realloc"];
    defaultsResult.supplyExports(instance.exports);
    if (deobfuscatorFactory) {
      const moduleToPass = debugInfoLocation === "auto" || debugInfoLocation === "embedded" ? module : null;
      const deobfuscator = createDeobfuscator(moduleToPass, debugInfo, deobfuscatorFactory);
      if (deobfuscator !== null) {
        defaultsResult.supplyStackDeobfuscator(deobfuscator);
      }
    }
    const teavm = {
      exports: userExports,
      instance,
      module
    };
    for (const key in instance.exports) {
      const exportObj = instance.exports[key];
      if (exportObj instanceof WebAssembly.Global) {
        Object.defineProperty(userExports, key, {
          get: () => exportObj.value
        });
      }
    }
    return teavm;
  }
  async function compileModule(src, isNodeJs) {
    if (typeof src !== "string") {
      return await WebAssembly.compile(src, { builtins: ["js-string"] });
    }
    const [response, close] = await openPath(src, isNodeJs);
    const result = await WebAssembly.compileStreaming(response, { builtins: ["js-string"] });
    close();
    return result;
  }
  var hasStringBuiltinsPromise = null;
  function hasStringBuiltins() {
    if (hasStringBuiltinsPromise === null) {
      hasStringBuiltinsPromise = (async () => {
        const bytes = new Int8Array([
          0,
          97,
          115,
          109,
          1,
          0,
          0,
          0,
          1,
          7,
          1,
          96,
          1,
          127,
          1,
          100,
          111,
          2,
          31,
          1,
          14,
          119,
          97,
          115,
          109,
          58,
          106,
          115,
          45,
          115,
          116,
          114,
          105,
          110,
          103,
          12,
          102,
          114,
          111,
          109,
          67,
          104,
          97,
          114,
          67,
          111,
          100,
          101,
          0,
          0,
          3,
          1,
          0,
          5,
          4,
          1,
          1,
          0,
          0,
          7,
          10,
          1,
          6,
          109,
          101,
          109,
          111,
          114,
          121,
          2,
          0,
          10,
          -127,
          -128,
          -128,
          0,
          0
        ]);
        try {
          const response = new Response(bytes, {
            headers: { "Content-Type": "application/wasm" }
          });
          const module = await WebAssembly.compileStreaming(response, { builtins: ["js-string"] });
          await WebAssembly.instantiate(module, {});
          return true;
        } catch (e) {
          return false;
        }
      })();
    }
    return hasStringBuiltinsPromise;
  }
  async function getDeobfuscator(path, options, isNodeJs) {
    if (typeof path !== "string" && !options.path) {
      return null;
    }
    try {
      const importObj = {};
      const module = await compileModule(options.path ?? `${path}-deobfuscator.wasm`, isNodeJs);
      const defaultsResult = defaults(importObj, {}, await hasStringBuiltins());
      await linkImports(importObj, {}, module, []);
      const instance = await WebAssembly.instantiate(module, importObj);
      defaultsResult.supplyExports(instance.exports);
      return instance;
    } catch (e) {
      console.warn("Could not load deobfuscator", e);
      return null;
    }
  }
  async function openPath(src, isNodeJs) {
    if (!isNodeJs) {
      const response = await fetch(src);
      return [response, () => {
      }];
    } else {
      const fs = await importNodeFs();
      const fileHandle = await fs.open(src, "r");
      const stream = await fileHandle.readableWebStream();
      const response = new Response(stream, {
        headers: { "Content-Type": "application/wasm" }
      });
      return [response, () => fileHandle.close()];
    }
  }
  var nodeFsImportObject;
  async function importNodeFs() {
    if (!nodeFsImportObject) {
      nodeFsImportObject = import("node:fs/promises");
    }
    return await nodeFsImportObject;
  }
  function createDeobfuscator(module, externalData, deobfuscatorFactory) {
    let deobfuscator = null;
    let deobfuscatorInitialized = false;
    function ensureDeobfuscator() {
      if (!deobfuscatorInitialized) {
        deobfuscatorInitialized = true;
        if (externalData !== null) {
          try {
            deobfuscator = deobfuscatorFactory.exports["createFromExternalFile"].value(externalData);
          } catch (e) {
            console.warn("Could not load create deobfuscator", e);
          }
        }
        if (deobfuscator == null && module !== null) {
          try {
            deobfuscator = deobfuscatorFactory.exports["createForModule"].value(module);
          } catch (e) {
            console.warn("Could not create deobfuscator from module data", e);
          }
        }
      }
    }
    return (addresses) => {
      ensureDeobfuscator();
      return deobfuscator !== null ? deobfuscator.deobfuscate(addresses) : [];
    };
  }
  async function fetchExternalDebugInfo(path, debugInfoLocation, options, isNodeJs) {
    if (!options.enabled) {
      return null;
    }
    if (typeof path !== "string" && !options.externalInfoPath) {
      return null;
    }
    if (debugInfoLocation !== "auto" && debugInfoLocation !== "external") {
      return null;
    }
    if (typeof options.externalInfoPath === "object" && options.externalInfoPath instanceof Int8Array) {
      return options.externalInfoPath;
    }
    const location = options.externalInfoPath ?? path + ".teadbg";
    let buffer;
    if (!isNodeJs) {
      const response = await fetch(location);
      if (!response.ok) {
        return null;
      }
      buffer = await response.arrayBuffer();
    } else {
      const fs = await importNodeFs();
      buffer = (await fs.readFile(location)).buffer;
    }
    return new Int8Array(buffer);
  }
  async function loadEmscriptenModules(emscriptenModulePaths, isNodeJs) {
    const keysValues = Object.entries(emscriptenModulePaths);
    return Promise.all(keysValues.map(async ([key, { pathToJs, pathToWasm }]) => {
      const [response, close] = await openPath(pathToWasm, isNodeJs);
      const [jsLoader, wasmModule] = await Promise.all([
        import(pathToJs),
        WebAssembly.compileStreaming(response)
      ]);
      const result = {
        name: key,
        jsLoader: jsLoader.default,
        wasmModule
      };
      close();
      return result;
    }));
  }

  // src/main/js/wasm-gc-runtime/simple-wrapper.ts
  var teavmGlobal = globalThis;
  var ns = teavmGlobal["TeaVM"] || {};
  teavmGlobal["TeaVM"] = ns;
  ns["wasmGC"] = ns["wasmGC"] || { load, defaults, wrapImport };
})();

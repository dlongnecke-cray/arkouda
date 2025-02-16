module ParquetMsg {
  use CTypes, IO;
  use ServerErrors, ServerConfig;
  use FileIO;
  use FileSystem;
  use GenSymIO;
  use List;
  use Logging;
  use Message;
  use MultiTypeSymbolTable;
  use MultiTypeSymEntry;
  use NumPyDType;
  use Sort;
  use CommAggregation;
  use AryUtil;
  use Map;

  use SegmentedString;
  use SegmentedArray;

  enum CompressionType {
    NONE=0,
    SNAPPY=1,
    GZIP=2,
    BROTLI=3,
    ZSTD=4,
    LZ4=5
  };


  // Use reflection for error information
  use Reflection;
  require "ArrowFunctions.h";
  require "ArrowFunctions.o";

  private config const logLevel = ServerConfig.logLevel;
  private config const logChannel = ServerConfig.logChannel;
  const pqLogger = new Logger(logLevel, logChannel);
  config const TRUNCATE: int = 0;
  config const APPEND: int = 1;
  
  private config const ROWGROUPS = 512*1024*1024 / numBytes(int); // 512 mb of int64
  // Undocumented for now, just for internal experiments
  private config const batchSize = getEnvInt("ARKOUDA_SERVER_PARQUET_BATCH_SIZE", 8192);

  extern var ARROWINT64: c_int;
  extern var ARROWINT32: c_int;
  extern var ARROWUINT64: c_int;
  extern var ARROWUINT32: c_int;
  extern var ARROWBOOLEAN: c_int;
  extern var ARROWSTRING: c_int;
  extern var ARROWFLOAT: c_int;
  extern var ARROWLIST: c_int;
  extern var ARROWDOUBLE: c_int;
  extern var ARROWERROR: c_int;

  enum ArrowTypes { int64, int32, uint64, uint32,
                    stringArr, timestamp, boolean,
                    double, float, list, notimplemented };

  record parquetErrorMsg {
    var errMsg: c_ptr(uint(8));
    proc init() {
      errMsg = c_nil;
    }
    
    proc deinit() {
      extern proc c_free_string(ptr);
      c_free_string(errMsg);
    }

    proc parquetError(lineNumber, routineName, moduleName) throws {
      extern proc strlen(a): int;
      var err: string;
      try {
        err = createStringWithNewBuffer(errMsg, strlen(errMsg));
      } catch e {
        err = "Error converting Parquet error message to Chapel string";
      }
      throw getErrorWithContext(
                     msg=err,
                     lineNumber,
                     routineName,
                     moduleName,
                     errorClass="ParquetError");
    }
  }
  
  proc getVersionInfo() {
    extern proc c_getVersionInfo(): c_string;
    extern proc strlen(str): c_int;
    extern proc c_free_string(ptr);
    var cVersionString = c_getVersionInfo();
    defer {
      c_free_string(cVersionString: c_void_ptr);
    }
    var ret: string;
    try {
      ret = createStringWithNewBuffer(cVersionString,
                                strlen(cVersionString));
    } catch e {
      ret = "Error converting Arrow version message to Chapel string";
    }
    return ret;
  }
  
  proc getSubdomains(lengths: [?FD] int) {
    var subdoms: [FD] domain(1);
    var offset = 0;
    for i in FD {
      subdoms[i] = {offset..#lengths[i]};
      offset += lengths[i];
    }
    return (subdoms, (+ reduce lengths));
  }

  proc readFilesByName(A: [] ?t, filenames: [] string, sizes: [] int, dsetname: string, ty) throws {
    extern proc c_readColumnByName(filename, chpl_arr, colNum, numElems, startIdx, batchSize, errMsg): int;
    var (subdoms, length) = getSubdomains(sizes);
    var fileOffsets = (+ scan sizes) - sizes;
    
    coforall loc in A.targetLocales() do on loc {
      var locFiles = filenames;
      var locFiledoms = subdoms;
      var locOffsets = fileOffsets;
      
      try {
        forall (off, filedom, filename) in zip(locOffsets, locFiledoms, locFiles) {
          for locdom in A.localSubdomains() {
            const intersection = domain_intersection(locdom, filedom);
            
            if intersection.size > 0 {
              var pqErr = new parquetErrorMsg();
              if c_readColumnByName(filename.localize().c_str(), c_ptrTo(A[intersection.low]),
                                    dsetname.localize().c_str(), intersection.size, intersection.low - off,
                                    batchSize,
                                    c_ptrTo(pqErr.errMsg)) == ARROWERROR {
                pqErr.parquetError(getLineNumber(), getRoutineName(), getModuleName());
              }
            }
          }
        }
      } catch e {
        throw e;
      }
    }
  }

  proc readStrFilesByName(A: [] ?t, filenames: [] string, sizes: [] int, dsetname: string, ty) throws {
    extern proc c_readColumnByName(filename, chpl_arr, colNum, numElems, startIdx, batchSize, errMsg): int;
    var (subdoms, length) = getSubdomains(sizes);
    
    coforall loc in A.targetLocales() do on loc {
      var locFiles = filenames;
      var locFiledoms = subdoms;

      try {
        forall (filedom, filename) in zip(locFiledoms, locFiles) {
          for locdom in A.localSubdomains() {
            const intersection = domain_intersection(locdom, filedom);

            if intersection.size > 0 {
              var pqErr = new parquetErrorMsg();
              var col: [filedom] t;

              if c_readColumnByName(filename.localize().c_str(), c_ptrTo(col),
                                    dsetname.localize().c_str(), intersection.size, 0,
                                    batchSize, c_ptrTo(pqErr.errMsg)) == ARROWERROR {
                pqErr.parquetError(getLineNumber(), getRoutineName(), getModuleName());
              }
              A[filedom] = col;
            }
          }
        }
      } catch e {
        throw e;
      }
    }
  }

  proc readListFilesByName(A: [] ?t, filenames: [] string, sizes: [] int, dsetname: string, ty) throws {
    extern proc c_readListColumnByName(filename, chpl_arr, colNum, numElems, startIdx, batchSize, errMsg): int;
    var (subdoms, length) = getSubdomains(sizes);
    
    coforall loc in A.targetLocales() do on loc {
      var locFiles = filenames;
      var locFiledoms = subdoms;

      try {
        forall (filedom, filename) in zip(locFiledoms, locFiles) {
          for locdom in A.localSubdomains() {
            const intersection = domain_intersection(locdom, filedom);

            if intersection.size > 0 {
              var pqErr = new parquetErrorMsg();
              var col: [filedom] t;

              if c_readListColumnByName(filename.localize().c_str(), c_ptrTo(col),
                                    dsetname.localize().c_str(), intersection.size, 0,
                                    batchSize, c_ptrTo(pqErr.errMsg)) == ARROWERROR {
                pqErr.parquetError(getLineNumber(), getRoutineName(), getModuleName());
              }
              A[filedom] = col;
            }
          }
        }
      } catch e {
        throw e;
      }
    }
  }

  proc calcListSizesandOffset(offsets: [] ?t, filenames: [] string, sizes: [] int, dsetname: string) throws {
    var (subdoms, length) = getSubdomains(sizes);

    var listSizes: [filenames.domain] int;
    coforall loc in offsets.targetLocales() do on loc {
      var locFiles = filenames;
      var locFiledoms = subdoms;
      
      try {
        forall (i, filedom, filename) in zip(sizes.domain, locFiledoms, locFiles) {
          for locdom in offsets.localSubdomains() {
            const intersection = domain_intersection(locdom, filedom);
            if intersection.size > 0 {
              var col: [filedom] t;
              listSizes[i] = getListColSize(filename, dsetname, col);
              offsets[filedom] = col;
            }
          }
        }
      } catch e {
        throw e;
      }
    }
    return listSizes;
  }

  proc calcStrSizesAndOffset(offsets: [] ?t, filenames: [] string, sizes: [] int, dsetname: string) throws {
    var (subdoms, length) = getSubdomains(sizes);

    var byteSizes: [filenames.domain] int;

    coforall loc in offsets.targetLocales() do on loc {
      var locFiles = filenames;
      var locFiledoms = subdoms;
      
      try {
        forall (i, filedom, filename) in zip(sizes.domain, locFiledoms, locFiles) {
          for locdom in offsets.localSubdomains() {
            const intersection = domain_intersection(locdom, filedom);
            if intersection.size > 0 {
              var col: [filedom] t;
              byteSizes[i] = getStrColSize(filename, dsetname, col);
              offsets[filedom] = col;
            }
          }
        }
      } catch e {
        throw e;
      }
    }
    return byteSizes;
  }

  proc getNullIndices(A: [] ?t, filenames: [] string, sizes: [] int, dsetname: string, ty) throws {
    extern proc c_getStringColumnNullIndices(filename, colname, chpl_nulls, errMsg): int;
    var (subdoms, length) = getSubdomains(sizes);
    
    coforall loc in A.targetLocales() do on loc {
      var locFiles = filenames;
      var locFiledoms = subdoms;
      
      try {
        forall (filedom, filename) in zip(locFiledoms, locFiles) {
          for locdom in A.localSubdomains() {
            const intersection = domain_intersection(locdom, filedom);
            
            if intersection.size > 0 {
              var pqErr = new parquetErrorMsg();
              var col: [filedom] t;
              if c_getStringColumnNullIndices(filename.localize().c_str(), dsetname.localize().c_str(),
                                              c_ptrTo(col), pqErr.errMsg) {
                pqErr.parquetError(getLineNumber(), getRoutineName(), getModuleName());
              }
              A[filedom] = col;
            }
          }
        }
      } catch e {
        throw e;
      }
    }
  }

  proc getStrColSize(filename: string, dsetname: string, offsets: [] int) throws {
    extern proc c_getStringColumnNumBytes(filename, colname, offsets, numElems, startIdx, errMsg): int;
    var pqErr = new parquetErrorMsg();

    var byteSize = c_getStringColumnNumBytes(filename.localize().c_str(),
                                             dsetname.localize().c_str(),
                                             c_ptrTo(offsets),
                                             offsets.size, 0,
                                             c_ptrTo(pqErr.errMsg));
    
    if byteSize == ARROWERROR then
      pqErr.parquetError(getLineNumber(), getRoutineName(), getModuleName());
    return byteSize;
  }

  proc getListColSize(filename: string, dsetname: string, offsets: [] int) throws {
    extern proc c_getListColumnSize(filename, colname, offsets, numElems, startIdx, errMsg): int;
    var pqErr = new parquetErrorMsg();

    var listSize = c_getListColumnSize(filename.localize().c_str(),
                                             dsetname.localize().c_str(),
                                             c_ptrTo(offsets),
                                             offsets.size, 0,
                                             c_ptrTo(pqErr.errMsg));
    
    if listSize == ARROWERROR then
      pqErr.parquetError(getLineNumber(), getRoutineName(), getModuleName());
    return listSize;
  }
  
  proc getArrSize(filename: string) throws {
    extern proc c_getNumRows(chpl_str, errMsg): int;
    var pqErr = new parquetErrorMsg();
    
    var size = c_getNumRows(filename.localize().c_str(),
                            c_ptrTo(pqErr.errMsg));
    if size == ARROWERROR {
      pqErr.parquetError(getLineNumber(), getRoutineName(), getModuleName());
    }
    return size;
  }

  proc getArrType(filename: string, colname: string) throws {
    extern proc c_getType(filename, colname, errMsg): c_int;
    var pqErr = new parquetErrorMsg();
    var arrType = c_getType(filename.localize().c_str(),
                            colname.localize().c_str(),
                            c_ptrTo(pqErr.errMsg));
    if arrType == ARROWERROR {
      pqErr.parquetError(getLineNumber(), getRoutineName(), getModuleName());
    }
    
    if arrType == ARROWINT64 then return ArrowTypes.int64;
    else if arrType == ARROWINT32 then return ArrowTypes.int32;
    else if arrType == ARROWUINT32 then return ArrowTypes.uint32;
    else if arrType == ARROWUINT64 then return ArrowTypes.uint64;
    else if arrType == ARROWBOOLEAN then return ArrowTypes.boolean;
    else if arrType == ARROWSTRING then return ArrowTypes.stringArr;
    else if arrType == ARROWDOUBLE then return ArrowTypes.double;
    else if arrType == ARROWFLOAT then return ArrowTypes.float;
    else if arrType == ARROWLIST then return ArrowTypes.list;
    throw getErrorWithContext(
                  msg="Unrecognized Parquet data type",
                  getLineNumber(),
                  getRoutineName(),
                  getModuleName(),
                  errorClass="ParquetError");
    return ArrowTypes.notimplemented;
  }

  proc getListData(filename: string, dsetname: string) throws {
    extern proc c_getListType(filename, dsetname, errMsg): c_int;
    var pqErr = new parquetErrorMsg();
    
    var t = c_getListType(filename.localize().c_str(), dsetname.localize().c_str(), c_ptrTo(pqErr.errMsg));
    if t == ARROWINT64 then return ArrowTypes.int64;
    else if t == ARROWINT32 then return ArrowTypes.int32;
    else if t == ARROWUINT32 then return ArrowTypes.uint32;
    else if t == ARROWUINT64 then return ArrowTypes.uint64;
    else if t == ARROWBOOLEAN then return ArrowTypes.boolean;
    // else if t == ARROWSTRING then return ArrowTypes.stringArr; // TODO - add handling for this case
    else if t == ARROWDOUBLE then return ArrowTypes.double;
    else if t == ARROWFLOAT then return ArrowTypes.float;
    else if t == ARROWLIST then return ArrowTypes.list;
    throw getErrorWithContext(
                  msg="Unrecognized Parquet data type",
                  getLineNumber(),
                  getRoutineName(),
                  getModuleName(),
                  errorClass="ParquetError");
    return ArrowTypes.notimplemented;
  }

  proc toCDtype(dtype: string) throws {
    select dtype {
      when 'int64' {
        return ARROWINT64;
      } when 'uint32' {
        return ARROWUINT32;
      } when 'uint64' {
        return ARROWUINT64;
      } when 'bool' {
        return ARROWBOOLEAN;
      } when 'float64' {
        return ARROWDOUBLE;
      } when 'str' {
        return ARROWSTRING;
      } otherwise {
         throw getErrorWithContext(
                msg="Trying to convert unrecognized dtype to Parquet type",
                getLineNumber(),
                getRoutineName(),
                getModuleName(),
                errorClass="ParquetError");
        return ARROWERROR;
      }
    }
  }

  proc writeDistArrayToParquet(A, filename, dsetname, dtype, rowGroupSize, compression, mode) throws {
    extern proc c_writeColumnToParquet(filename, chpl_arr, colnum,
                                       dsetname, numelems, rowGroupSize,
                                       dtype, compression, errMsg): int;
    extern proc c_appendColumnToParquet(filename, chpl_arr,
                                        dsetname, numelems,
                                        dtype, compression,
                                        errMsg): int;
    // var filenames: [0..#A.targetLocales().size] string;
    var dtypeRep = toCDtype(dtype);
    // for i in 0..#A.targetLocales().size {
    //   var suffix = '%04i'.format(i): string;
    //   filenames[i] = filename + "_LOCALE" + suffix + ".parquet";
    // }
    
    // var matchingFilenames = glob("%s_LOCALE*%s".format(filename, ".parquet"));
    var prefix: string;
    var extension: string;
  
    (prefix, extension) = getFileMetadata(filename);

    // Generate the filenames based upon the number of targetLocales.
    var filenames = generateFilenames(prefix, extension, A.targetLocales().size);

    //Generate a list of matching filenames to test against. 
    var matchingFilenames = getMatchingFilenames(prefix, extension);

    var filesExist = processParquetFilenames(filenames, matchingFilenames, mode);

    if mode == APPEND {
      if filesExist {
        var datasets = getDatasets(filenames[0]);
        if datasets.contains(dsetname) then
          throw getErrorWithContext(
                    msg="A column with name " + dsetname + " already exists in Parquet file",
                    lineNumber=getLineNumber(), 
                    routineName=getRoutineName(), 
                    moduleName=getModuleName(), 
                    errorClass='WriteModeError');
      }
    }
    
    coforall (loc, idx) in zip(A.targetLocales(), filenames.domain) do on loc {
        var pqErr = new parquetErrorMsg();
        const myFilename = filenames[idx];

        var locDom = A.localSubdomain();
        var locArr = A[locDom];
        if mode == TRUNCATE || !filesExist {
          if c_writeColumnToParquet(myFilename.localize().c_str(), c_ptrTo(locArr), 0,
                                    dsetname.localize().c_str(), locDom.size, rowGroupSize,
                                    dtypeRep, compression, c_ptrTo(pqErr.errMsg)) == ARROWERROR {
            pqErr.parquetError(getLineNumber(), getRoutineName(), getModuleName());
          }
        } else {
          if c_appendColumnToParquet(myFilename.localize().c_str(), c_ptrTo(locArr),
                                     dsetname.localize().c_str(), locDom.size,
                                     dtypeRep, compression, c_ptrTo(pqErr.errMsg)) == ARROWERROR {
            pqErr.parquetError(getLineNumber(), getRoutineName(), getModuleName());
          }
        }
      }
    // Only warn when files are being overwritten in truncate mode
    return filesExist && mode == TRUNCATE;
  }

  proc createEmptyParquetFile(filename: string, dsetname: string, dtype: int, compression: int) throws {
    extern proc c_createEmptyParquetFile(filename, dsetname, dtype,
                                         compression, errMsg): int;
    var pqErr = new parquetErrorMsg();
    if c_createEmptyParquetFile(filename.localize().c_str(), dsetname.localize().c_str(),
                                dtype, compression, c_ptrTo(pqErr.errMsg)) == ARROWERROR {
      pqErr.parquetError(getLineNumber(), getRoutineName(), getModuleName());
    }
  }
  
  // TODO: do we want to add offset writing for Parquet string writes?
  //       if we do, then we need to add the load offsets functionality
  //       in the string reading function
  proc write1DDistStringsAggregators(filename: string, mode: int, dsetName: string, entry: SegStringSymEntry, compression: int) throws {
    var segString = new SegString("", entry);
    ref ss = segString;
    var A = ss.offsets.a;

    // var filenames: [0..#A.targetLocales().size] string;
    // for i in 0..#A.targetLocales().size {
    //   var suffix = '%04i'.format(i): string;
    //   filenames[i] = filename + "_LOCALE" + suffix + ".parquet";
    // }
    
    // var matchingFilenames = glob("%s_LOCALE*%s".format(filename, ".parquet"));

    var prefix: string;
    var extension: string;
  
    (prefix, extension) = getFileMetadata(filename);

    // Generate the filenames based upon the number of targetLocales.
    var filenames = generateFilenames(prefix, extension, A.targetLocales().size);

    //Generate a list of matching filenames to test against. 
    var matchingFilenames = getMatchingFilenames(prefix, extension);

    var filesExist = processParquetFilenames(filenames, matchingFilenames, mode);

    if mode == APPEND {
      if filesExist {
        var datasets = getDatasets(filenames[0]);
        if datasets.contains(dsetName) then
          throw getErrorWithContext(
                   msg="A column with name " + dsetName + " already exists in Parquet file",
                   lineNumber=getLineNumber(), 
                   routineName=getRoutineName(), 
                   moduleName=getModuleName(), 
                   errorClass='WriteModeError');
      }
    }
    
    const extraOffset = ss.values.size;
    const lastOffset = A[A.domain.high];
    const lastValIdx = ss.values.a.domain.high;
    // For each locale gather the string bytes corresponding to the offsets in its local domain
    coforall (loc, idx) in zip(A.targetLocales(), filenames.domain) with (ref ss) do on loc {
        const myFilename = filenames[idx];

        const locDom = A.localSubdomain();
        var dims: [0..#1] int;
        dims[0] = locDom.size: int;

        if (locDom.isEmpty() || locDom.size <= 0) {
          if mode == APPEND && filesExist then
            throw getErrorWithContext(
                 msg="Parquet columns must each have the same length: " + myFilename,
                 lineNumber=getLineNumber(), 
                 routineName=getRoutineName(), 
                 moduleName=getModuleName(), 
                 errorClass='WriteModeError');
          createEmptyParquetFile(myFilename, dsetName, ARROWSTRING, compression);
        } else {
          var localOffsets = A[locDom];
          var startValIdx = localOffsets[locDom.low];

          var endValIdx = if (lastOffset == localOffsets[locDom.high]) then lastValIdx else A[locDom.high + 1] - 1;
                
          var valIdxRange = startValIdx..endValIdx;
          var localVals: [valIdxRange] uint(8);
          ref olda = ss.values.a;
          forall (localVal, valIdx) in zip(localVals, valIdxRange) with (var agg = newSrcAggregator(uint(8))) {
            // Copy the remote value at index position valIdx to our local array
            agg.copy(localVal, olda[valIdx]); // in SrcAgg, the Right Hand Side is REMOTE
          }
          var locOffsets: [0..#locDom.size+1] int;
          locOffsets[0..#locDom.size] = A[locDom];
          if locDom.high == A.domain.high then
            locOffsets[locOffsets.domain.high] = extraOffset;
          else
            locOffsets[locOffsets.domain.high] = A[locDom.high+1];
          
          writeStringsComponentToParquet(myFilename, dsetName, localVals, locOffsets, ROWGROUPS, compression, mode, filesExist);
        }
      }
    return filesExist && mode == TRUNCATE;
  }

  private proc writeStringsComponentToParquet(filename, dsetname, values: [] uint(8), offsets: [] int, rowGroupSize, compression, mode, filesExist) throws {
    extern proc c_writeStrColumnToParquet(filename, chpl_arr, chpl_offsets,
                                          dsetname, numelems, rowGroupSize,
                                          dtype, compression, errMsg): int;
    extern proc c_appendColumnToParquet(filename, chpl_arr,
                                        dsetname, numelems,
                                        dtype, compression,
                                        errMsg): int;
    var pqErr = new parquetErrorMsg();
    var dtypeRep = ARROWSTRING;
    if mode == TRUNCATE || !filesExist {
      if c_writeStrColumnToParquet(filename.localize().c_str(), c_ptrTo(values), c_ptrTo(offsets),
                                   dsetname.localize().c_str(), offsets.size-1, rowGroupSize,
                                   dtypeRep, compression, c_ptrTo(pqErr.errMsg)) == ARROWERROR {
        pqErr.parquetError(getLineNumber(), getRoutineName(), getModuleName());
      }
    } else if mode == APPEND {
      if c_appendColumnToParquet(filename.localize().c_str(), c_ptrTo(values),
                                 dsetname.localize().c_str(), offsets.size-1,
                                 dtypeRep, compression, c_ptrTo(pqErr.errMsg)) {
        pqErr.parquetError(getLineNumber(), getRoutineName(), getModuleName());
      }
    }
  }

  proc processParquetFilenames(filenames: [] string, matchingFilenames: [] string, mode: int) throws {
    var filesExist: bool = true;
    if mode == APPEND {
      if matchingFilenames.size == 0 {
        // Files do not exist, so we can just create the files
        filesExist = false;
      }
      else if matchingFilenames.size != filenames.size {
        throw getErrorWithContext(
                   msg="Appending to existing files must be done with the same number " +
                      "of locales. Try saving with a different directory or filename prefix?",
                   lineNumber=getLineNumber(), 
                   routineName=getRoutineName(), 
                   moduleName=getModuleName(), 
                   errorClass='MismatchedAppendError'
              );
      }
    } else if mode == TRUNCATE {
      if matchingFilenames.size > 0 {
        filesExist = true;
      } else {
        filesExist = false;
      }
    } else {
      throw getErrorWithContext(
                 msg="The mode %t is invalid".format(mode),
                 lineNumber=getLineNumber(), 
                 routineName=getRoutineName(), 
                 moduleName=getModuleName(), 
                 errorClass='IllegalArgumentError');
    }
    return filesExist;
  }

  proc write1DDistArrayParquet(filename: string, dsetname, dtype, compression, mode, A) throws {
    return writeDistArrayToParquet(A, filename, dsetname, dtype, ROWGROUPS, compression, mode);
  }

  proc parseListDataset(filenames: [] string, dsetname: string, len: int, sizes: [] int, st: borrowed SymTab) throws {
    // len here is our segment size
    var ty = getListData(filenames[0], dsetname);
    var filedom = filenames.domain;
    var segments = makeDistArray(len, int);
    var listSizes: [filedom] int = calcListSizesandOffset(segments, filenames, sizes, dsetname);
    var rtnmap: map(string, string) = new map(string, string);

    if ty == ArrowTypes.int64 || ty == ArrowTypes.int32 {
      var values = makeDistArray((+ reduce listSizes), int);
      readListFilesByName(values, filenames, listSizes, dsetname, ty);
      var segArray = getSegArray(segments, values, st);
      segArray.fillReturnMap(rtnmap, st);
      return "%jt".format(rtnmap);
    }
    else if ty == ArrowTypes.uint64 || ty == ArrowTypes.uint32 {
      var values = makeDistArray((+ reduce listSizes), uint);
      readListFilesByName(values, filenames, listSizes, dsetname, ty);
      var segArray = getSegArray(segments, values, st);
      segArray.fillReturnMap(rtnmap, st);
      return "%jt".format(rtnmap);
    }
    else if ty == ArrowTypes.double || ty == ArrowTypes.float {
      var values = makeDistArray((+ reduce listSizes), real);
      readListFilesByName(values, filenames, listSizes, dsetname, ty);
      var segArray = getSegArray(segments, values, st);
      segArray.fillReturnMap(rtnmap, st);
      return "%jt".format(rtnmap);
    }
    else if ty == ArrowTypes.boolean {
      var values = makeDistArray((+ reduce listSizes), bool);
      readListFilesByName(values, filenames, listSizes, dsetname, ty);
      var segArray = getSegArray(segments, values, st);
      segArray.fillReturnMap(rtnmap, st);
      return "%jt".format(rtnmap);
    }
    // TODO - add handling for Strings
    else {
      throw getErrorWithContext(
                 msg="Invalid Arrow Type",
                 lineNumber=getLineNumber(), 
                 routineName=getRoutineName(), 
                 moduleName=getModuleName(), 
                 errorClass='IllegalArgumentError');
    }
  }

  proc readAllParquetMsg(cmd: string, msgArgs: borrowed MessageArgs, st: borrowed SymTab): MsgTuple throws {
    var repMsg: string;
    var strictTypes: bool = msgArgs.get("strict_types").getBoolValue();

    var allowErrors: bool = msgArgs.get("allow_errors").getBoolValue(); // default is false
    if allowErrors {
        pqLogger.warn(getModuleName(), getRoutineName(), getLineNumber(), "Allowing file read errors");
    }
    
    var ndsets = msgArgs.get("dset_size").getIntValue();
    var nfiles = msgArgs.get("filename_size").getIntValue();
    var dsetlist: [0..#ndsets] string;
    var filelist: [0..#nfiles] string;

    try {
        dsetlist = msgArgs.get("dsets").getList(ndsets);
    } catch {
        // limit length of dataset names to 2000 chars
        var n: int = 1000;
        var jsondsets = msgArgs.getValueOf("dsets");
        var dsets: string = if jsondsets.size > 2*n then jsondsets[0..#n]+'...'+jsondsets[jsondsets.size-n..#n] else jsondsets;
        var errorMsg = "Could not decode json dataset names via tempfile (%i files: %s)".format(
                                            ndsets, dsets);
        pqLogger.error(getModuleName(),getRoutineName(),getLineNumber(),errorMsg);
        return new MsgTuple(errorMsg, MsgType.ERROR);
    }

    try {
        filelist = msgArgs.get("filenames").getList(nfiles);
    } catch {
        // limit length of file names to 2000 chars
        var n: int = 1000;
        var jsonfiles = msgArgs.getValueOf("filenames");
        var files: string = if jsonfiles.size > 2*n then jsonfiles[0..#n]+'...'+jsonfiles[jsonfiles.size-n..#n] else jsonfiles;
        var errorMsg = "Could not decode json filenames via tempfile (%i files: %s)".format(nfiles, files);
        pqLogger.error(getModuleName(),getRoutineName(),getLineNumber(),errorMsg);
        return new MsgTuple(errorMsg, MsgType.ERROR);
    }

    var dsetdom = dsetlist.domain;
    var filedom = filelist.domain;
    var dsetnames: [dsetdom] string;
    var filenames: [filedom] string;
    dsetnames = dsetlist;

    if filelist.size == 1 {
        if filelist[0].strip().size == 0 {
            var errorMsg = "filelist was empty.";
            pqLogger.error(getModuleName(),getRoutineName(),getLineNumber(),errorMsg);
            return new MsgTuple(errorMsg, MsgType.ERROR);
        }
        var tmp = glob(filelist[0]);
        pqLogger.debug(getModuleName(),getRoutineName(),getLineNumber(),
                              "glob expanded %s to %i files".format(filelist[0], tmp.size));
        if tmp.size == 0 {
            var errorMsg = "The wildcarded filename %s either corresponds to files inaccessible to Arkouda or files of an invalid format".format(filelist[0]);
            pqLogger.error(getModuleName(),getRoutineName(),getLineNumber(),errorMsg);
            return new MsgTuple(errorMsg, MsgType.ERROR);
        }
        // Glob returns filenames in weird order. Sort for consistency
        sort(tmp);
        filedom = tmp.domain;
        filenames = tmp;
    } else {
        filenames = filelist;
    }

    var fileErrors: list(string);
    var fileErrorCount:int = 0;
    var fileErrorMsg:string = "";
    var sizes: [filedom] int;
    var types: [dsetdom] ArrowTypes;
    var byteSizes: [filedom] int;

    var rnames: list((string, string, string)); // tuple (dsetName, item type, id)
    
    for (dsetidx, dsetname) in zip(dsetdom, dsetnames) do {
        for (i, fname) in zip(filedom, filenames) {
            var hadError = false;
            try {
                types[dsetidx] = getArrType(fname, dsetname);
                sizes[i] = getArrSize(fname);
            } catch e : Error {
                // This is only type of error thrown by Parquet
                fileErrorMsg = "Other error in accessing file %s: %s".format(fname,e.message());
                pqLogger.error(getModuleName(),getRoutineName(),getLineNumber(),fileErrorMsg);
                hadError = true;
                if !allowErrors { return new MsgTuple(fileErrorMsg, MsgType.ERROR); }
            }

            // This may need to be adjusted for this all-in-one approach
            if hadError {
              // Keep running total, but we'll only report back the first 10
              if fileErrorCount < 10 {
                fileErrors.append(fileErrorMsg.replace("\n", " ").replace("\r", " ").replace("\t", " ").strip());
              }
              fileErrorCount += 1;
            }
        }
        var len = + reduce sizes;
        var ty = types[dsetidx];

        // Only integer is implemented for now, do nothing if the Parquet
        // file has a different type
        if ty == ArrowTypes.int64 || ty == ArrowTypes.int32 {
          var entryVal = new shared SymEntry(len, int);
          readFilesByName(entryVal.a, filenames, sizes, dsetname, ty);
          var valName = st.nextName();
          st.addEntry(valName, entryVal);
          rnames.append((dsetname, "pdarray", valName));
        } else if ty == ArrowTypes.uint64 || ty == ArrowTypes.uint32 {
          var entryVal = new shared SymEntry(len, uint);
          readFilesByName(entryVal.a, filenames, sizes, dsetname, ty);
          var valName = st.nextName();
          st.addEntry(valName, entryVal);
          rnames.append((dsetname, "pdarray", valName));
        } else if ty == ArrowTypes.boolean {
          var entryVal = new shared SymEntry(len, bool);
          readFilesByName(entryVal.a, filenames, sizes, dsetname, ty);
          var valName = st.nextName();
          st.addEntry(valName, entryVal);
          rnames.append((dsetname, "pdarray", valName));
        } else if ty == ArrowTypes.stringArr {
          var entrySeg = new shared SymEntry(len, int);
          byteSizes = calcStrSizesAndOffset(entrySeg.a, filenames, sizes, dsetname);
          entrySeg.a = (+ scan entrySeg.a) - entrySeg.a;
          
          var entryVal = new shared SymEntry((+ reduce byteSizes), uint(8));
          readStrFilesByName(entryVal.a, filenames, byteSizes, dsetname, ty);
          
          var stringsEntry = assembleSegStringFromParts(entrySeg, entryVal, st);
          rnames.append((dsetname, "seg_string", "%s+%t".format(stringsEntry.name, stringsEntry.nBytes)));
        } else if ty == ArrowTypes.double || ty == ArrowTypes.float {
          var entryVal = new shared SymEntry(len, real);
          readFilesByName(entryVal.a, filenames, sizes, dsetname, ty);
          var valName = st.nextName();
          st.addEntry(valName, entryVal);
          rnames.append((dsetname, "pdarray", valName));
        } else if ty == ArrowTypes.list {
          var create_str: string = parseListDataset(filenames, dsetname, len, sizes, st);
          rnames.append((dsetname, "seg_array", create_str));
        } else {
          var errorMsg = "DType %s not supported for Parquet reading".format(ty);
          pqLogger.error(getModuleName(),getRoutineName(),getLineNumber(),errorMsg);
          return new MsgTuple(errorMsg, MsgType.ERROR);
        }
    }

    repMsg = _buildReadAllMsgJson(rnames, false, 0, fileErrors, st);
    pqLogger.debug(getModuleName(),getRoutineName(),getLineNumber(),repMsg);
    return new MsgTuple(repMsg,MsgType.NORMAL);
  }

  proc getDatasets(filename) throws {
    extern proc c_getDatasetNames(filename, dsetResult, errMsg): int(32);
    extern proc strlen(a): int;
    var pqErr = new parquetErrorMsg();
    var res: c_ptr(uint(8));
    defer {
      extern proc c_free_string(ptr);
      c_free_string(res);
    }
    if c_getDatasetNames(filename.c_str(), c_ptrTo(res),
                         c_ptrTo(pqErr.errMsg)) == ARROWERROR {
      pqErr.parquetError(getLineNumber(), getRoutineName(), getModuleName());
    }
    var datasets: string;
    try! datasets = createStringWithNewBuffer(res, strlen(res));
    return new list(datasets.split(","));
  }
  
  proc toparquetMsg(cmd: string, msgArgs: borrowed MessageArgs, st: borrowed SymTab): MsgTuple throws {
    var mode = msgArgs.get("mode").getIntValue();
    var filename: string = msgArgs.getValueOf("prefix");
    var entry = st.lookup(msgArgs.getValueOf("values"));
    var dsetname = msgArgs.getValueOf("dset");
    var dataType = msgArgs.getValueOf("dtype");
    
    var entryDtype = DType.UNDEF;
    if (entry.isAssignableTo(SymbolEntryType.TypedArraySymEntry)) {
      entryDtype = (entry: borrowed GenSymEntry).dtype;
    } else if (entry.isAssignableTo(SymbolEntryType.SegStringSymEntry)) {
      entryDtype = (entry: borrowed SegStringSymEntry).dtype;
    } else {
      var errorMsg = "toparquetMsg Unsupported SymbolEntryType:%t".format(entry.entryType);
      return new MsgTuple(errorMsg, MsgType.ERROR);
    }

    var compression = msgArgs.getValueOf("compression").toUpper(): CompressionType;

    var warnFlag: bool;

    try {
      select entryDtype {
          when DType.Int64 {
            var e = toSymEntry(toGenSymEntry(entry), int);
            warnFlag = write1DDistArrayParquet(filename, dsetname, dataType, compression:int, mode, e.a);
          }
          when DType.UInt64 {
            var e = toSymEntry(toGenSymEntry(entry), uint);
            warnFlag = write1DDistArrayParquet(filename, dsetname, dataType, compression:int, mode, e.a);
          }
          when DType.Bool {
            var e = toSymEntry(toGenSymEntry(entry), bool);
            warnFlag = write1DDistArrayParquet(filename, dsetname, dataType, compression:int, mode, e.a);
          } when DType.Float64 {
            var e = toSymEntry(toGenSymEntry(entry), real);
            warnFlag = write1DDistArrayParquet(filename, dsetname, dataType, compression:int, mode, e.a);
          } when DType.Strings {
            var segString:SegStringSymEntry = toSegStringSymEntry(entry);
            warnFlag = write1DDistStringsAggregators(filename, mode, dsetname, segString, compression:int);
          } otherwise {
            var errorMsg = "Writing Parquet files is only supported for int arrays";
            pqLogger.error(getModuleName(),getRoutineName(),getLineNumber(),errorMsg);
            return new MsgTuple(errorMsg, MsgType.ERROR);
          }
        }
    } catch e: FileNotFoundError {
      var errorMsg = "Unable to open %s for writing: %s".format(filename,e.message());
      pqLogger.error(getModuleName(),getRoutineName(),getLineNumber(),errorMsg);
      return new MsgTuple(errorMsg, MsgType.ERROR);
    } catch e: MismatchedAppendError {
      var errorMsg = "Mismatched append %s".format(e.message());
      pqLogger.error(getModuleName(),getRoutineName(),getLineNumber(),errorMsg);
      return new MsgTuple(errorMsg, MsgType.ERROR);
    } catch e: WriteModeError {
      var errorMsg = "Write mode error %s".format(e.message());
      pqLogger.error(getModuleName(),getRoutineName(),getLineNumber(),errorMsg);
      return new MsgTuple(errorMsg, MsgType.ERROR);
    } catch e: Error {
      var errorMsg = "problem writing to file %s".format(e.message());
      pqLogger.error(getModuleName(),getRoutineName(),getLineNumber(),errorMsg);
      return new MsgTuple(errorMsg, MsgType.ERROR);
    }
    if warnFlag {
      var warnMsg = "Warning: possibly overwriting existing files matching filename pattern";
      return new MsgTuple(warnMsg, MsgType.WARNING);
    } else {
      var repMsg = "wrote array to file";
      pqLogger.debug(getModuleName(),getRoutineName(),getLineNumber(),repMsg);
      return new MsgTuple(repMsg, MsgType.NORMAL);
    }
  }

  proc writeMultiColParquet(filename: string, col_names: [] string, 
                              ncols: int, sym_names: [] string, targetLocales: [] locale, 
                              compression: int, st: borrowed SymTab): bool throws {

    extern proc c_writeMultiColToParquet(filename, column_names, ptr_arr,
                                      datatypes, colnum, numelems, rowGroupSize, compression, errMsg): int;

    var prefix: string;
    var extension: string;
    (prefix, extension) = getFileMetadata(filename);

    // Generate the filenames based upon the number of targetLocales.
    var filenames = generateFilenames(prefix, extension, targetLocales.size);

    //Generate a list of matching filenames to test against. 
    var matchingFilenames = getMatchingFilenames(prefix, extension);

    // TODO when APPEND is fully deprecated update this to not need the mode.
    var filesExist = processParquetFilenames(filenames, matchingFilenames, TRUNCATE); // set to truncate. We will not be supporting appending. 

    coforall (loc, idx) in zip(targetLocales, filenames.domain) do on loc {
      var pqErr = new parquetErrorMsg();
      const fname = filenames[idx];

      var ptrList: [0..#ncols] c_void_ptr;
      var datatypes: [0..#ncols] int;
      var sizeList: [0..#ncols] int;

      var my_column_names = col_names;
      var c_names: [0..#ncols] c_string;

      var locSize: int = 0;
      var sections_sizes: [0..#ncols] int; // only fill in sizes for str columns
      forall (i, column) in zip(0..#ncols, sym_names) with (+ reduce locSize) {
        var entry = st.lookup(column);
        // need to calculate the total size of Strings on this local
        if (entry.isAssignableTo(SymbolEntryType.SegStringSymEntry)) {
          var e: SegStringSymEntry = toSegStringSymEntry(entry);
          var segStr = new SegString("", e);
          ref ss = segStr;
          var lens = ss.getLengths();
          const locDom = ss.offsets.a.localSubdomain();
          var x: int;
          for i in locDom do x += lens[i];
          sections_sizes[i] = x;
          locSize += x;
        }
      }

      var str_vals: [0..#locSize] uint(8);
      var str_idx = (+ scan sections_sizes) - sections_sizes;
      forall (i, column, si) in zip(0..#ncols, sym_names, str_idx) {
        // generate the local c string list of column names
        c_names[i] = my_column_names[i].localize().c_str();

        var entry = st.lookup(column);

        // access the dtype of each 
        var entryDtype = DType.UNDEF;
        if (entry.isAssignableTo(SymbolEntryType.TypedArraySymEntry)) {
          entryDtype = (entry: borrowed GenSymEntry).dtype;
        } else if (entry.isAssignableTo(SymbolEntryType.SegStringSymEntry)) {
          entryDtype = (entry: borrowed SegStringSymEntry).dtype;
        } else {
          throw getErrorWithContext(
              msg="Unknown SymEntry Type",
              lineNumber=getLineNumber(), 
              routineName=getRoutineName(), 
              moduleName=getModuleName(), 
              errorClass='ValueError'
          );
        }
        
        select entryDtype {
          when DType.Int64 {
            var e = toSymEntry(toGenSymEntry(entry), int);
            var locDom = e.a.localSubdomain();
            // set the pointer to the entry array in the list of Pointers
            ptrList[i] = c_ptrTo(e.a[locDom]): c_void_ptr;
            datatypes[i] = ARROWINT64;
            sizeList[i] = locDom.size;
          }
          when DType.UInt64 {
            var e = toSymEntry(toGenSymEntry(entry), uint);
            var locDom = e.a.localSubdomain();
            // set the pointer to the entry array in the list of Pointers
            ptrList[i] = c_ptrTo(e.a[locDom]): c_void_ptr;
            datatypes[i] = ARROWUINT64;
            sizeList[i] = locDom.size;
          }
          when DType.Bool {
            var e = toSymEntry(toGenSymEntry(entry), bool);
            var locDom = e.a.localSubdomain();
            // set the pointer to the entry array in the list of Pointers
            ptrList[i] = c_ptrTo(e.a[locDom]): c_void_ptr;
            datatypes[i] = ARROWBOOLEAN;
            sizeList[i] = locDom.size;
          } when DType.Float64 {
            var e = toSymEntry(toGenSymEntry(entry), real);
            var locDom = e.a.localSubdomain();
            // set the pointer to the entry array in the list of Pointers
            ptrList[i] = c_ptrTo(e.a[locDom]): c_void_ptr;
            datatypes[i] = ARROWDOUBLE;
            sizeList[i] = locDom.size;
          } when DType.Strings {
            var e: SegStringSymEntry = toSegStringSymEntry(entry);
            var segStr = new SegString("", e);
            ref ss = segStr;
            var A = ss.offsets.a;
            const lastOffset = A[A.domain.high];
            const lastValIdx = ss.values.a.domain.high;
            const locDom = ss.offsets.a.localSubdomain();

            var localOffsets = A[locDom];
            var startValIdx = localOffsets[locDom.low];
            var endValIdx = if (lastOffset == localOffsets[locDom.high]) then lastValIdx else A[locDom.high + 1] - 1;
            var valIdxRange = startValIdx..endValIdx;
            ref olda = ss.values.a;
            str_vals[si..#valIdxRange.size] = olda[valIdxRange];
            ptrList[i] = c_ptrTo(str_vals[si]): c_void_ptr;
            datatypes[i] = ARROWSTRING;
            sizeList[i] = locDom.size;
          } otherwise {
            throw getErrorWithContext(
                              msg="Writing Parquet files (multi-column) does not support columns of type %s".format(entryDtype),
                              lineNumber=getLineNumber(), 
                              routineName=getRoutineName(), 
                              moduleName=getModuleName(), 
                              errorClass='DataTypeError'
            );
          }
        }
      }
      
      // validate all elements same size
      var numelems: int = sizeList[0];
      if !(&& reduce (sizeList==numelems)) {
        throw getErrorWithContext(
              msg="Parquet columns must be the same size",
              lineNumber=getLineNumber(), 
              routineName=getRoutineName(), 
              moduleName=getModuleName(), 
              errorClass='WriteModeError'
        );
      }
      var result: int = c_writeMultiColToParquet(fname.localize().c_str(), c_ptrTo(c_names), c_ptrTo(ptrList), c_ptrTo(datatypes), ncols, numelems, ROWGROUPS, compression, c_ptrTo(pqErr.errMsg));
    }
    return filesExist;
  }

  proc toParquetMultiColMsg(cmd: string, msgArgs: borrowed MessageArgs, st: borrowed SymTab): MsgTuple throws {
    const filename: string = msgArgs.getValueOf("filename");
    const ncols: int = msgArgs.get("num_cols").getIntValue();

    // get list of the names for the columns
    var col_names: [0..#ncols] string = msgArgs.get("col_names").getList(ncols);

    // get list of sym entry names holding column data
    var sym_names: [0..#ncols] string = msgArgs.get("columns").getList(ncols);

    // compression format as integer
    var compression = msgArgs.getValueOf("compression").toUpper(): CompressionType;

    // Assuming all columns have same distribution, access the first to get target locales
    var entry = st.lookup(sym_names[0]);

    // access the dtype to create symentry from abstract
    var entryDtype = DType.UNDEF;
    if (entry.isAssignableTo(SymbolEntryType.TypedArraySymEntry)) {
      entryDtype = (entry: borrowed GenSymEntry).dtype;
    } else if (entry.isAssignableTo(SymbolEntryType.SegStringSymEntry)) {
      entryDtype = (entry: borrowed SegStringSymEntry).dtype;
    } else {
      throw getErrorWithContext(
          msg="Unknown SymEntry Type",
          lineNumber=getLineNumber(), 
          routineName=getRoutineName(), 
          moduleName=getModuleName(), 
          errorClass='ValueError'
      );
    }

    var targetLocales;
    select entryDtype {
      when DType.Int64 {
        var e = toSymEntry(toGenSymEntry(entry), int);
        targetLocales = e.a.targetLocales();
      }
      when DType.UInt64 {
        var e = toSymEntry(toGenSymEntry(entry), uint);
        targetLocales = e.a.targetLocales();
      }
      when DType.Bool {
        var e = toSymEntry(toGenSymEntry(entry), bool);
        targetLocales = e.a.targetLocales();
      } when DType.Float64 {
        var e = toSymEntry(toGenSymEntry(entry), real);
        targetLocales = e.a.targetLocales();
      } when DType.Strings {
        var e: SegStringSymEntry = toSegStringSymEntry(entry);
        var segStr = new SegString("", e);
        targetLocales = segStr.offsets.a.targetLocales();
      } otherwise {
        throw getErrorWithContext(
                          msg="Writing Parquet files (multi-column) does not support columns of type %s".format(entryDtype),
                          lineNumber=getLineNumber(), 
                          routineName=getRoutineName(), 
                          moduleName=getModuleName(), 
                          errorClass='DataTypeError'
        );
      }
    }

    var warnFlag: bool;
    try {
      warnFlag = writeMultiColParquet(filename, col_names, ncols, sym_names, targetLocales, compression:int, st);
    } catch e: FileNotFoundError {
      var errorMsg = "Unable to open %s for writing: %s".format(filename,e.message());
      pqLogger.error(getModuleName(),getRoutineName(),getLineNumber(),errorMsg);
      return new MsgTuple(errorMsg, MsgType.ERROR);
    } catch e: WriteModeError {
      var errorMsg = "Write mode error %s".format(e.message());
      pqLogger.error(getModuleName(),getRoutineName(),getLineNumber(),errorMsg);
      return new MsgTuple(errorMsg, MsgType.ERROR);
    } catch e: Error {
      var errorMsg = "problem writing to file %s".format(e.message());
      pqLogger.error(getModuleName(),getRoutineName(),getLineNumber(),errorMsg);
      return new MsgTuple(errorMsg, MsgType.ERROR);
    }

    if warnFlag {
      var warnMsg = "Warning: possibly overwriting existing files matching filename pattern";
      return new MsgTuple(warnMsg, MsgType.WARNING);
    } else {
      var repMsg = "wrote array to file";
      pqLogger.debug(getModuleName(),getRoutineName(),getLineNumber(),repMsg);
      return new MsgTuple(repMsg, MsgType.NORMAL);
    }
  }

  proc lspqMsg(cmd: string, msgArgs: borrowed MessageArgs, st: borrowed SymTab): MsgTuple throws {
    // reqMsg: "lshdf [<json_filename>]"
    var repMsg: string;

    // Retrieve filename from payload
    var filename: string = msgArgs.getValueOf("filename");
    if filename.isEmpty() {
      var errorMsg = "Filename was Empty";
      pqLogger.error(getModuleName(),getRoutineName(),getLineNumber(),errorMsg);
      return new MsgTuple(errorMsg, MsgType.ERROR);
    }

    // If the filename represents a glob pattern, retrieve the locale 0 filename
    if isGlobPattern(filename) {
      // Attempt to interpret filename as a glob expression and ls the first result
      var tmp = glob(filename);

      if tmp.size <= 0 {
        var errorMsg = "Cannot retrieve filename from glob expression %s, check file name or format".format(filename);
        return new MsgTuple(errorMsg, MsgType.ERROR);
      }
            
      // Set filename to globbed filename corresponding to locale 0
      filename = tmp[tmp.domain.first];
    }
        
    // Check to see if the file exists. If not, return an error message
    if !exists(filename) {
      var errorMsg = "File %s does not exist in a location accessible to Arkouda".format(filename);
      return new MsgTuple(errorMsg,MsgType.ERROR);
    }
        
    try {
      extern proc c_getDatasetNames(filename, dsetResult, errMsg): int(32);
      extern proc strlen(a): int;
      var pqErr = new parquetErrorMsg();
      var res: c_ptr(uint(8));
      defer {
        extern proc c_free_string(ptr);
        c_free_string(res);
      }
      if c_getDatasetNames(filename.c_str(), c_ptrTo(res),
                           c_ptrTo(pqErr.errMsg)) == ARROWERROR {
        pqErr.parquetError(getLineNumber(), getRoutineName(), getModuleName());
      }
      try! repMsg = createStringWithNewBuffer(res, strlen(res));
      var items = new list(repMsg.split(",")); // convert to json

      repMsg = "%jt".format(items);
    } catch e : Error {
      var errorMsg = "Failed to process Parquet file %t".format(e.message());
      return new MsgTuple(errorMsg, MsgType.ERROR);
    }

    return new MsgTuple(repMsg, MsgType.NORMAL);
  }

  proc nullIndicesMsg(cmd: string, msgArgs: borrowed MessageArgs, st: borrowed SymTab): MsgTuple throws {
    var repMsg: string;

    var ndsets = msgArgs.get("dset_size").getIntValue();
    var nfiles = msgArgs.get("filename_size").getIntValue();
    var dsetlist: [0..#ndsets] string;
    var filelist: [0..#nfiles] string;

    try {
      dsetlist = msgArgs.get("dsets").getList(ndsets);
    } catch {
      var errorMsg = "Could not decode json dataset names via tempfile (%i files: %s)".format(
                                                                                              1, msgArgs.getValueOf("dsets"));
      pqLogger.error(getModuleName(),getRoutineName(),getLineNumber(),errorMsg);
      return new MsgTuple(errorMsg, MsgType.ERROR);
    }

    try {
      filelist = msgArgs.get("filenames").getList(nfiles);
    } catch {
      // limit length of file names to 2000 chars
      var n: int = 1000;
      var jsonfiles = msgArgs.getValueOf("filenames");
      var files: string = if jsonfiles.size > 2*n then jsonfiles[0..#n]+'...'+jsonfiles[jsonfiles.size-n..#n] else jsonfiles;
      var errorMsg = "Could not decode json filenames via tempfile (%i files: %s)".format(nfiles, files);
      pqLogger.error(getModuleName(),getRoutineName(),getLineNumber(),errorMsg);
      return new MsgTuple(errorMsg, MsgType.ERROR);
    }

    var dsetdom = dsetlist.domain;
    var filedom = filelist.domain;
    var dsetnames: [dsetdom] string;
    var filenames: [filedom] string;
    dsetnames = dsetlist;

    if filelist.size == 1 {
      if filelist[0].strip().size == 0 {
        var errorMsg = "filelist was empty.";
        pqLogger.error(getModuleName(),getRoutineName(),getLineNumber(),errorMsg);
        return new MsgTuple(errorMsg, MsgType.ERROR);
      }
      var tmp = glob(filelist[0]);
      pqLogger.debug(getModuleName(),getRoutineName(),getLineNumber(),
                     "glob expanded %s to %i files".format(filelist[0], tmp.size));
      if tmp.size == 0 {
        var errorMsg = "The wildcarded filename %s either corresponds to files inaccessible to Arkouda or files of an invalid format".format(filelist[0]);
        pqLogger.error(getModuleName(),getRoutineName(),getLineNumber(),errorMsg);
        return new MsgTuple(errorMsg, MsgType.ERROR);
      }
      // Glob returns filenames in weird order. Sort for consistency
      sort(tmp);
      filedom = tmp.domain;
      filenames = tmp;
    } else {
      filenames = filelist;
    }

    var fileErrors: list(string);
    var fileErrorCount:int = 0;
    var fileErrorMsg:string = "";
    var sizes: [filedom] int;
    var types: [dsetdom] ArrowTypes;
    var byteSizes: [filedom] int;

    var rnames: list((string, string, string)); // tuple (dsetName, item type, id)
    
    for (dsetidx, dsetname) in zip(dsetdom, dsetnames) do {
        for (i, fname) in zip(filedom, filenames) {
            var hadError = false;
            try {
                types[dsetidx] = getArrType(fname, dsetname);
                sizes[i] = getArrSize(fname);
            } catch e : Error {
                // This is only type of error thrown by Parquet
                fileErrorMsg = "Other error in accessing file %s: %s".format(fname,e.message());
                pqLogger.error(getModuleName(),getRoutineName(),getLineNumber(),fileErrorMsg);
                hadError = true;
                return new MsgTuple(fileErrorMsg, MsgType.ERROR);
            }

            // This may need to be adjusted for this all-in-one approach
            if hadError {
              // Keep running total, but we'll only report back the first 10
              if fileErrorCount < 10 {
                fileErrors.append(fileErrorMsg.replace("\n", " ").replace("\r", " ").replace("\t", " ").strip());
              }
              fileErrorCount += 1;
            }
        }
        var len = + reduce sizes;
        var ty = types[dsetidx];
        
        if ty == ArrowTypes.stringArr {
          var entryVal = new shared SymEntry(len, int);
          getNullIndices(entryVal.a, filenames, sizes, dsetname, ty);
          var valName = st.nextName();
          st.addEntry(valName, entryVal);
          rnames.append((dsetname, "pdarray", valName));
        } else {
          var errorMsg = "Null indices only supported on Parquet string columns, not {} columns".format(ty);
          pqLogger.error(getModuleName(),getRoutineName(),getLineNumber(),errorMsg);
          return new MsgTuple(errorMsg, MsgType.ERROR);
        }
    }

    repMsg = _buildReadAllMsgJson(rnames, false, 0, fileErrors, st);
    pqLogger.debug(getModuleName(),getRoutineName(),getLineNumber(),repMsg);
    return new MsgTuple(repMsg,MsgType.NORMAL);
  }

  use CommandMap;
  registerFunction("readAllParquet", readAllParquetMsg, getModuleName());
  registerFunction("toParquet_multi", toParquetMultiColMsg, getModuleName());
  registerFunction("writeParquet", toparquetMsg, getModuleName());
  registerFunction("lspq", lspqMsg, getModuleName());
  registerFunction("getnullparquet", nullIndicesMsg, getModuleName());
  ServerConfig.appendToConfigStr("ARROW_VERSION", getVersionInfo());
}

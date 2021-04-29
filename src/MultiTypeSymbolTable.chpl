module MultiTypeSymbolTable
{
    use ServerConfig;
    use ServerErrorStrings;
    use Reflection;
    use Errors;
    use Logging;
    
    use MultiTypeSymEntry;
    use Map;
    use IO;
    
    private config const logLevel = ServerConfig.logLevel;
    const mtLogger = new Logger(logLevel);

    /* symbol table */
    class SymTab
    {
        /*
        Associative domain of strings
        */
        var registry: domain(string);

        /*
        Map indexed by strings
        */
        var tab: map(string, shared GenSymEntry);

        var nid = 0;
        /*
        Gives out symbol names.
        */
        proc nextName():string {
            nid += 1;
            return "id_"+ nid:string;
        }

        proc regName(name: string, userDefinedName: string) throws {

            // check to see if name is defined
            if (!tab.contains(name)) {
                mtLogger.error(getModuleName(),getRoutineName(),getLineNumber(),
                                     "regName: undefined symbol: %s".format(name));
                throw getErrorWithContext(
                                   msg=unknownSymbolError("regName", name),
                                   lineNumber=getLineNumber(),
                                   routineName=getRoutineName(),
                                   moduleName=getModuleName(),
                                   errorClass="UnknownSymbolError");
            }

            // check to see if userDefinedName is already defined, with in-place modification, this will be an error
            if (registry.contains(userDefinedName)) {
                mtLogger.error(getModuleName(),getRoutineName(),getLineNumber(),
                                     "regName: requested symbol `%s` is already in use".format(userDefinedName));
                throw getErrorWithContext(
                                    msg=incompatibleArgumentsError("regName", name),
                                    lineNumber=getLineNumber(),
                                    routineName=getRoutineName(),
                                    moduleName=getModuleName(),
                                    errorClass="ArgumentError");
            } else {
                mtLogger.debug(getModuleName(),getRoutineName(),getLineNumber(),
                                     "Registering symbol: %s ".format(userDefinedName));            
            }
            
            // RE: Issue#729 we no longer support multiple name registration of the same object
            if (registry.contains(name)) {
                registry -= name;
            }

            registry += userDefinedName; // add user defined name to registry

            // point at same shared table entry
            tab.addOrSet(userDefinedName, tab.getAndRemove(name));
        }

        proc unregName(name: string) throws {
            
            // check to see if name is defined
            if !tab.contains(name)  {
                mtLogger.error(getModuleName(),getRoutineName(),getLineNumber(),
                                             "unregName: undefined symbol: %s ".format(name));
                throw getErrorWithContext(
                                   msg=unknownSymbolError("regName", name),
                                   lineNumber=getLineNumber(),
                                   routineName=getRoutineName(),
                                   moduleName=getModuleName(),
                                   errorClass="UnknownSymbolError");
            } else {
                if registry.contains(name) {
                    mtLogger.debug(getModuleName(),getRoutineName(),getLineNumber(),
                                             "Unregistering symbol: %s ".format(name));  
                } else {
                    mtLogger.error(getModuleName(),getRoutineName(),getLineNumber(),
                                             "The symbol %s is not registered".format(name));                  
                }          
            }

            registry -= name; // take name out of registry
        }
        
        // is it an error to redefine an entry? ... probably not
        // this addEntry takes stuff to create a new SymEntry

        /*
        Takes args and creates a new SymEntry.

        :arg name: name of the array
        :type name: string

        :arg len: length of array
        :type len: int

        :arg t: type of array

        :returns: borrow of newly created `SymEntry(t)`
        */
        proc addEntry(name: string, len: int, type t): borrowed SymEntry(t) throws {
            // check and throw if memory limit would be exceeded
            if t == bool {overMemLimit(len);} else {overMemLimit(len*numBytes(t));}
            
            var entry = new shared SymEntry(len, t);
            if (tab.contains(name)) {
                mtLogger.debug(getModuleName(),getRoutineName(),getLineNumber(),
                                                        "redefined symbol: %s ".format(name));
            } else {
                mtLogger.debug(getModuleName(),getRoutineName(),getLineNumber(),
                                                        "adding symbol: %s ".format(name));            
            }

            tab.addOrSet(name, entry);
            return tab.getBorrowed(name).toSymEntry(t);
        }

        /*
        Takes an already created GenSymEntry and creates a new SymEntry.

        :arg name: name of the array
        :type name: string

        :arg entry: Generic Sym Entry to convert
        :type entry: GenSymEntry

        :returns: borrow of newly created GenSymEntry
        */
        proc addEntry(name: string, in entry: shared GenSymEntry): borrowed GenSymEntry throws {
            // check and throw if memory limit would be exceeded
            overMemLimit(entry.size*entry.itemsize);

            if (tab.contains(name)) {
                mtLogger.debug(getModuleName(),getRoutineName(),getLineNumber(),
                                                        "redefined symbol: %s ".format(name));
            } else {
                mtLogger.debug(getModuleName(),getRoutineName(),getLineNumber(),
                                                        "adding symbol: %s ".format(name));            
            }

            tab.addOrSet(name, entry);
            return tab.getBorrowed(name);
        }

        /*
        Creates a symEntry from array name, length, and DType

        :arg name: name of the array
        :type name: string

        :arg len: length of array
        :type len: int

        :arg dtype: type of array

        :returns: borrow of newly created GenSymEntry
        */
        proc addEntry(name: string, len: int, dtype: DType): borrowed GenSymEntry throws {
            select dtype {
                when DType.Int64 { return addEntry(name, len, int); }
                when DType.Float64 { return addEntry(name, len, real); }
                when DType.Bool { return addEntry(name, len, bool); }
                otherwise { 
                    var errorMsg = "addEntry not implemented for %t".format(dtype); 
                    throw getErrorWithContext(
                        msg=errorMsg,
                        lineNumber=getLineNumber(),
                        routineName=getRoutineName(),
                        moduleName=getModuleName(),
                        errorClass="IllegalArgumentError");
                }
            }
        }

        /*
        Removes an unregistered entry from the symTable

        :arg name: name of the array
        :type name: string

        :returns: bool indicating whether the deletion occurred
        */
        proc deleteEntry(name: string): bool throws {
            if tab.contains(name) { 
               if !registry.contains(name) {
                   mtLogger.debug(getModuleName(),getRoutineName(),getLineNumber(),
                                           "Deleting unregistered entry: %s".format(name)); 
                   tab.remove(name);
                   return true;
               } else {
                    mtLogger.debug(getModuleName(),getRoutineName(),getLineNumber(),
                                           "Skipping registered entry: %s".format(name)); 
                    return false;
               }            
            } else {
                if registry.contains(name) {
                    mtLogger.error(getModuleName(),getRoutineName(),getLineNumber(),
                                     "Registered entry is not in SymTab: %s".format(name));
                } else {
                    mtLogger.error(getModuleName(),getRoutineName(),getLineNumber(),
                                     "Unregistered entry is not in SymTab: %s".format(name));    
                }
                throw getErrorWithContext(
                    msg=unknownSymbolError(pname="deleteEntry", sname=name),
                    lineNumber=getLineNumber(),
                    routineName=getRoutineName(),
                    moduleName=getModuleName(),
                    errorClass="UnknownSymbolError");
            }
        }

        /*
        Clears all unregistered entries from the symTable
        */
        proc clear() throws {
            mtLogger.debug(getModuleName(),getRoutineName(),getLineNumber(),
                                           "Clearing all unregistered entries"); 
            for n in tab.keysToArray() { deleteEntry(n); }
        }

        
        /*
        Returns the sym entry associated with the provided name, if the sym entry exists

        :arg name: string to index/query in the sym table
        :type name: string

        :returns: sym entry or throws on error
        :throws: `unkownSymbolError(name)`
        */
        proc lookup(name: string): borrowed GenSymEntry throws {
            if (!tab.contains(name)) {
                throw getErrorWithContext(
                    msg=unknownSymbolError(pname="lookup", sname=name),
                    lineNumber=getLineNumber(),
                    routineName=getRoutineName(),
                    moduleName=getModuleName(),
                    errorClass="UnknownSymbolError");
            } else {
                mtLogger.debug(getModuleName(),getRoutineName(),getLineNumber(),
                                                "found symbol: %s".format(name));
                return tab.getBorrowed(name);
            }
        }

        /*
        checks to see if a symbol is defined if it is not it throws an exception 
        */
        proc check(name: string) throws { 
            if (!tab.contains(name)) { 
                mtLogger.error(getModuleName(),getRoutineName(),getLineNumber(),
                                                "undefined symbol: %s".format(name));
                throw getErrorWithContext(
                    msg=unknownSymbolError(pname="check", sname=name),
                    lineNumber=getLineNumber(),
                    routineName=getRoutineName(),
                    moduleName=getModuleName(),
                    errorClass="UnknownSymbolError");
            } else {
                mtLogger.debug(getModuleName(),getRoutineName(),getLineNumber(),
                                                "found symbol: %s".format(name));
            }
        }
        
        /*
        Prints the SymTable in a pretty format (name,SymTable[name])
        */
        proc pretty() throws {
            for n in tab {
                writeln("%10s = ".format(n), tab.getValue(n)); stdout.flush();
            }
        }

        /*
        returns total bytes in arrays in the symbol table
        */
        proc memUsed(): int {
            var total: int = + reduce [e in tab.values()] e.size * e.itemsize;
            return total;
        }
        
        /*
        Attempts to format and return sym entries mapped to the provided string into JSON format.
        Pass __AllSymbols__ to process the entire sym table.

        :arg name: name of entry to be processed
        :type name: string
        */
        proc dump(name:string): string throws {
            if name == "__AllSymbols__" {
                return "%jt".format(this);
            } else if (tab.contains(name)) {
                return "%jt %jt".format(name, tab.getReference(name));
            } else {
                throw getErrorWithContext(
                    msg=unknownSymbolError(pname="dump",sname=name),
                    lineNumber=getLineNumber(),
                    routineName=getRoutineName(),
                    moduleName=getModuleName(),
                    errorClass="UnknownSymbolError");
            }
        }
        
        /*
        Returns verbose attributes of the sym entries at the given string, if the string is a JSON formmated list of entry names.
        Pass __AllSymbols__ to process all sym entries in the sym table.
        Pass __RegisteredSymbols__ to process all registered sym entries.

        Returns: name, dtype, size, ndim, shape, item size, and registration status for each entry in names

        :arg names: list containing names of entries to be processed
        :type names: string

        :returns: JSON formatted list containing info for each entry in names
        */
        proc info(names:string): string throws {
            var entries;
            select names
            {
                when "__AllSymbols__"         {entries = getEntries(tab);}
                when "__RegisteredSymbols__"  {entries = getEntries(registry);}
                otherwise                     {entries = getEntries(parseJson(names));}
            }
            return "[%s]".format(','.join(entries));
        }

        /*
        Convert JSON formmated list of entry names into a [] string object

        :arg names: JSON formatted list containing entry names
        :type names: string

        :returns: [] string of entry names
        */
        proc parseJson(names:string): [] string throws {
            var mem = openmem();
            var writer = mem.writer().write(names);
            var reader = mem.reader();

            var num_elements = 0;
            for i in names.split(',') {
                num_elements += 1;
            }

            var parsed_names: [1..num_elements] string;
            reader.readf("%jt", parsed_names);
            return parsed_names;
        }

        /*
        Returns an array of JSON formatted strings for each entry in infoList (tab, registry, or [names])

        :arg infoList: Iterable containing sym entries to be returned by info
        :type infoList: map(string, shared GenSymEntry), domain(string), or [] string
                        for tab, registry, and [names] respectively

        :returns: array of JSON formatted strings
        */
        proc getEntries(infoList): [] string throws {
            var entries: [1..infoList.size] string;
            var i = 0;
            for name in infoList {
                i+=1;
                check(name);
                entries[i] = formatEntry(name, tab.getBorrowed(name));
            }
            return entries;
        }

        /*
        Returns formatted string for an info entry.

        :arg name: name of entry to be formatted
        :type name: string

        :arg item: Generic Sym Entry to be formatted (tab.getBorrowed(name))
        :type item: GenSymEntry

        :returns: JSON formatted dictionary
        */
        proc formatEntry(name:string, item:borrowed GenSymEntry): string throws {
            return '{"name":%jt, "dtype":%jt, "size":%jt, "ndim":%jt, "shape":%jt, "itemsize":%jt, "registered":%jt}'.format(name,
                              dtype2str(item.dtype), item.size, item.ndim, item.shape, item.itemsize, registry.contains(name));
        }

        /*
        Returns raw attributes of the sym entry at the given string, if the string maps to an entry.
        Returns: name, dtype, size, ndim, shape, and item size

        :arg name: name of entry to be processed
        :type name: string

        :returns: s (string) containing info
        */
        proc attrib(name:string):string throws {
            var s:string;
            if (tab.contains(name)) {
                s = "%s %s %t %t %t %t".format(name, dtype2str(tab.getBorrowed(name).dtype), 
                          tab.getBorrowed(name).size, tab.getBorrowed(name).ndim, 
                          tab.getBorrowed(name).shape, tab.getBorrowed(name).itemsize);
            }
            else {
                throw getErrorWithContext(
                    msg=unknownSymbolError("attrib",name),
                    lineNumber=getLineNumber(),
                    routineName=getRoutineName(),
                    moduleName=getModuleName(),
                    errorClass="UnknownSymbolError");                   
            }
            return s;
        }

        /*
        Attempts to find a sym entry mapped to the provided string, then 
        returns the data in the entry up to the specified threshold.
        Arrays of size less than threshold will be printed in their entirety. 
        Arrays of size greater than or equal to threshold will print the first 3 and last 3 elements

        :arg name: name of entry to be processed
        :type name: string

        :arg thresh: threshold for data to return
        :type thresh: int

        :returns: s (string) containing the array data
        */
        proc datastr(name: string, thresh:int): string throws {
            var s:string;
            if (tab.contains(name)) {
                var u: borrowed GenSymEntry = tab.getBorrowed(name);
                select u.dtype
                {
                    when DType.Int64
                    {
                        var e = toSymEntry(u,int);
                        if e.size == 0 {s =  "[]";}
                        else if e.size < thresh || e.size <= 6 {
                            s =  "[";
                            for i in 0..(e.size-2) {s += try! "%t ".format(e.a[i]);}
                            s += try! "%t]".format(e.a[e.size-1]);
                        }
                        else {
                            s = try! "[%t %t %t ... %t %t %t]".format(e.a[0],e.a[1],e.a[2],
                                                                      e.a[e.size-3],
                                                                      e.a[e.size-2],
                                                                      e.a[e.size-1]);
                        }
                    }
                    when DType.Float64
                    {
                        var e = toSymEntry(u,real);
                        if e.size == 0 {s =  "[]";}
                        else if e.size < thresh || e.size <= 6 {
                            s =  "[";
                            for i in 0..(e.size-2) {s += try! "%t ".format(e.a[i]);}
                            s += try! "%t]".format(e.a[e.size-1]);
                        }
                        else {
                            s = try! "[%t %t %t ... %t %t %t]".format(e.a[0],e.a[1],e.a[2],
                                                                      e.a[e.size-3],
                                                                      e.a[e.size-2],
                                                                      e.a[e.size-1]);
                        }
                    }
                    when DType.Bool
                    {
                        var e = toSymEntry(u,bool);
                        if e.size == 0 {s =  "[]";}
                        else if e.size < thresh || e.size <= 6 {
                            s =  "[";
                            for i in 0..(e.size-2) {s += try! "%t ".format(e.a[i]);}
                            s += try! "%t]".format(e.a[e.size-1]);
                        }
                        else {
                            s = try! "[%t %t %t ... %t %t %t]".format(e.a[0],e.a[1],e.a[2],
                                                                      e.a[e.size-3],
                                                                      e.a[e.size-2],
                                                                      e.a[e.size-1]);
                        }
                        s = s.replace("true","True");
                        s = s.replace("false","False");
                    }
                    otherwise {
                        s = unrecognizedTypeError("datastr",dtype2str(u.dtype));
                        mtLogger.error(getModuleName(),getRoutineName(),getLineNumber(),s);                        
                    }
                }
            }
            else {
                throw getErrorWithContext(
                    msg=unknownSymbolError("datastr",name),
                    lineNumber=getLineNumber(),
                    routineName=getRoutineName(),
                    moduleName=getModuleName(),
                    errorClass="UnknownSymbolError");                          
            }
            return s;
        }
        /*
        Attempts to find a sym entry mapped to the provided string, then 
        returns the data in the entry up to the specified threshold. 
        This method returns the data in form "array([<DATA>])".
        Arrays of size less than threshold will be printed in their entirety. 
        Arrays of size greater than or equal to threshold will print the first 3 and last 3 elements

        :arg name: name of entry to be processed
        :type name: string

        :arg thresh: threshold for data to return
        :type thresh: int

        :returns: s (string) containing the array data
        */
        proc datarepr(name: string, thresh:int): string throws {
            var s:string;
            if (tab.contains(name)) {
                var u: borrowed GenSymEntry = tab.getBorrowed(name);
                select u.dtype
                {
                    when DType.Int64
                    {
                        var e = toSymEntry(u,int);
                        if e.size == 0 {s =  "array([])";}
                        else if e.size < thresh || e.size <= 6 {
                            s =  "array([";
                            for i in 0..(e.size-2) {s += try! "%t, ".format(e.a[i]);}
                            s += try! "%t])".format(e.a[e.size-1]);
                        }
                        else {
                            s = try! "array([%t, %t, %t, ..., %t, %t, %t])".format(e.a[0],e.a[1],e.a[2],
                                                                                    e.a[e.size-3],
                                                                                    e.a[e.size-2],
                                                                                    e.a[e.size-1]);
                        }
                    }
                    when DType.Float64
                    {
                        var e = toSymEntry(u,real);
                        if e.size == 0 {s =  "array([])";}
                        else if e.size < thresh || e.size <= 6 {
                            s =  "array([";
                            for i in 0..(e.size-2) {s += try! "%.17r, ".format(e.a[i]);}
                            s += try! "%.17r])".format(e.a[e.size-1]);
                        }
                        else {
                            s = try! "array([%.17r, %.17r, %.17r, ..., %.17r, %.17r, %.17r])".format(e.a[0],e.a[1],e.a[2],
                                                                                    e.a[e.size-3],
                                                                                    e.a[e.size-2],
                                                                                    e.a[e.size-1]);
                        }
                    }
                    when DType.Bool
                    {
                        var e = toSymEntry(u,bool);
                        if e.size == 0 {s =  "array([])";}
                        else if e.size < thresh || e.size <= 6 {
                            s =  "array([";
                            for i in 0..(e.size-2) {s += try! "%t, ".format(e.a[i]);}
                            s += try! "%t])".format(e.a[e.size-1]);
                        }
                        else {
                            s = try! "array([%t, %t, %t, ..., %t, %t, %t])".format(e.a[0],e.a[1],e.a[2],
                                                                                    e.a[e.size-3],
                                                                                    e.a[e.size-2],
                                                                                    e.a[e.size-1]);
                        }
                        s = s.replace("true","True");
                        s = s.replace("false","False");
                    }
                    otherwise {
                        throw getErrorWithContext(
                            msg=unrecognizedTypeError("datarepr",dtype2str(u.dtype)),
                            lineNumber=getLineNumber(),
                            routineName=getRoutineName(),
                            moduleName=getModuleName(),
                            errorClass="TypeError");                            
                    }
                }
            }
            else {
                throw getErrorWithContext(
                    msg=unknownSymbolError("datarepr",name),
                    lineNumber=getLineNumber(),
                    routineName=getRoutineName(),
                    moduleName=getModuleName(),
                    errorClass="UnknownSymbolError");                  
            }
            return s;
        }
    }      
}

// Decompile the functions containing the given addresses, and their callees.
//
// Args: <output directory> <depth> <address> [address ...]
// Each function goes to its own file, with its callers and callees listed on top.
//@category Analysis
import java.io.File;
import java.io.PrintWriter;
import java.util.ArrayList;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Set;
import java.util.TreeSet;

import ghidra.app.decompiler.DecompInterface;
import ghidra.app.decompiler.DecompileResults;
import ghidra.app.script.GhidraScript;
import ghidra.program.model.listing.Function;
import ghidra.program.model.listing.FunctionManager;
import ghidra.program.model.symbol.Reference;
import ghidra.program.model.symbol.ReferenceManager;

public class DecompileAt extends GhidraScript {
    @Override
    public void run() throws Exception {
        String[] args = getScriptArgs();
        if (args.length < 3) {
            printerr("usage: <output directory> <depth> <address> [address ...]");
            return;
        }
        File directory = new File(args[0]);
        if (!directory.isDirectory() && !directory.mkdirs()) {
            printerr("cannot create " + directory);
            return;
        }
        int depth = Integer.decode(args[1]);
        FunctionManager functions = currentProgram.getFunctionManager();
        ReferenceManager references = currentProgram.getReferenceManager();
        Set<Function> chosen = new LinkedHashSet<>();
        List<Object[]> queue = new ArrayList<>();
        for (int i = 2; i < args.length; i++) {
            Function function = functions.getFunctionContaining(toAddr(Long.decode(args[i])));
            if (function == null) {
                printerr("no function at " + args[i]);
                continue;
            }
            if (chosen.add(function)) {
                queue.add(new Object[] {function, 0});
            }
        }
        List<Function> selected = new ArrayList<>();
        while (!queue.isEmpty()) {
            Object[] item = queue.remove(0);
            Function function = (Function) item[0];
            int level = (Integer) item[1];
            selected.add(function);
            if (level >= depth) {
                continue;
            }
            for (Function callee : function.getCalledFunctions(monitor)) {
                if (callee.isExternal() || callee.isThunk()) {
                    continue;
                }
                if (chosen.add(callee)) {
                    queue.add(new Object[] {callee, level + 1});
                }
            }
        }
        DecompInterface decompiler = new DecompInterface();
        decompiler.toggleCCode(true);
        decompiler.toggleSyntaxTree(true);
        decompiler.setSimplificationStyle("decompile");
        decompiler.openProgram(currentProgram);
        PrintWriter index = new PrintWriter(new File(directory, "index.txt"));
        int written = 0;
        for (Function function : selected) {
            Set<String> callers = new TreeSet<>();
            for (Reference reference : references.getReferencesTo(function.getEntryPoint())) {
                Function caller = functions.getFunctionContaining(reference.getFromAddress());
                if (caller != null && !caller.equals(function)) {
                    callers.add(caller.getName(true));
                }
            }
            Set<String> callees = new TreeSet<>();
            for (Function callee : function.getCalledFunctions(monitor)) {
                callees.add(callee.getName(true));
            }
            DecompileResults result = decompiler.decompileFunction(function, 120, monitor);
            String name = function.getName(true).replaceAll("[^A-Za-z0-9_]", "_");
            if (name.length() > 100) {
                name = name.substring(0, 100);
            }
            written++;
            PrintWriter out = new PrintWriter(new File(directory, String.format("%03d_%s.c", written, name)));
            out.println("// " + function.getName(true) + " @ " + function.getEntryPoint());
            out.println("// callers: " + callers);
            out.println("// callees: " + callees);
            if (result != null && result.decompileCompleted() && result.getDecompiledFunction() != null) {
                out.println(result.getDecompiledFunction().getC());
            } else {
                out.println("// decompile failed: " + (result != null ? result.getErrorMessage() : "no result"));
            }
            out.close();
            index.printf("%03d %s @ %s%n", written, function.getName(true), function.getEntryPoint());
        }
        index.close();
        decompiler.dispose();
        println("decompiled " + written + " functions into " + directory);
    }
}

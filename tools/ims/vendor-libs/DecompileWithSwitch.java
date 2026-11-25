// Give an indirect branch its jump table, then decompile the function around it.
//
// Args: <output file> <switch address> <table address> <count> <element size> <scale> <base>
//   target[i] = base + scale * element[i], elements read as little-endian of element size bytes
//@category Analysis
import java.io.File;
import java.io.PrintWriter;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.Map;

import ghidra.app.decompiler.DecompInterface;
import ghidra.app.decompiler.DecompileResults;
import ghidra.app.script.GhidraScript;
import ghidra.program.model.address.Address;
import ghidra.program.model.listing.Function;
import ghidra.program.model.pcode.JumpTable;

public class DecompileWithSwitch extends GhidraScript {
    @Override
    public void run() throws Exception {
        String[] args = getScriptArgs();
        if (args.length < 7) {
            printerr("usage: <output file> <switch> <table> <count> <element size> <scale> <base>");
            return;
        }
        Address instruction = toAddr(Long.decode(args[1]));
        Address table = toAddr(Long.decode(args[2]));
        int count = Integer.decode(args[3]);
        int size = Integer.decode(args[4]);
        long scale = Long.decode(args[5]);
        long base = Long.decode(args[6]);
        Map<Long, Address> targets = new HashMap<>();
        byte[] element = new byte[size];
        for (int i = 0; i < count; i++) {
            currentProgram.getMemory().getBytes(table.add(i * size), element);
            long value = 0;
            for (int b = size - 1; b >= 0; b--) {
                value = (value << 8) | (element[b] & 0xff);
            }
            targets.put((long) i, toAddr(base + scale * value));
        }
        Function function = currentProgram.getFunctionManager().getFunctionContaining(instruction);
        if (function == null) {
            printerr("no function at " + instruction);
            return;
        }
        ArrayList<Address> destinations = new ArrayList<>();
        for (int i = 0; i < count; i++) {
            destinations.add(targets.get((long) i));
        }
        new JumpTable(instruction, destinations, true).writeOverride(function);
        DecompInterface decompiler = new DecompInterface();
        decompiler.toggleCCode(true);
        decompiler.setSimplificationStyle("decompile");
        decompiler.openProgram(currentProgram);
        DecompileResults result = decompiler.decompileFunction(function, 300, monitor);
        PrintWriter out = new PrintWriter(new File(args[0]));
        out.println("// " + function.getName(true) + " @ " + function.getEntryPoint());
        if (result != null && result.decompileCompleted() && result.getDecompiledFunction() != null) {
            out.println(result.getDecompiledFunction().getC());
        } else {
            out.println("// decompile failed: " + (result != null ? result.getErrorMessage() : "no result"));
        }
        out.close();
        decompiler.dispose();
        println("wrote " + args[0]);
    }
}

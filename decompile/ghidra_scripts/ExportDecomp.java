// Decompile every function and write the common per-function CSV used by score.py.
// Args: <out.csv> <out.c> <timeout_seconds>
// @category BakeOff
import java.io.PrintWriter;

import ghidra.app.decompiler.DecompInterface;
import ghidra.app.decompiler.DecompileResults;
import ghidra.app.script.GhidraScript;
import ghidra.program.model.listing.Function;

public class ExportDecomp extends GhidraScript {
    @Override
    public void run() throws Exception {
        String[] args = getScriptArgs();
        int timeout = Integer.parseInt(args[2]);

        DecompInterface ifc = new DecompInterface();
        ifc.openProgram(currentProgram);
        long base = currentProgram.getImageBase().getOffset();

        try (PrintWriter csv = new PrintWriter(args[0]); PrintWriter src = new PrintWriter(args[1])) {
            csv.println("entry_offset,name,param_count,decompiled_ok,c_lines");
            for (Function f : currentProgram.getFunctionManager().getFunctions(true)) {
                if (monitor.isCancelled()) break;
                if (f.isThunk() || f.isExternal()) continue;
                long off = f.getEntryPoint().getOffset() - base;

                DecompileResults res = ifc.decompileFunction(f, timeout, monitor);
                boolean ok = res.decompileCompleted() && res.getDecompiledFunction() != null;
                int params = -1, lines = 0;
                if (ok) {
                    params = res.getHighFunction().getFunctionPrototype().getNumParams();
                    String c = res.getDecompiledFunction().getC();
                    lines = c.split("\n").length;
                    src.printf("// ==== 0x%x %s ====%n%s%n", off, f.getName(), c);
                }
                csv.printf("0x%x,%s,%d,%d,%d%n", off, f.getName(), params, ok ? 1 : 0, lines);
            }
        } finally {
            ifc.dispose();
        }
    }
}

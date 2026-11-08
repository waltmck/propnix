using System;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Linq;
class SigDump {
    static void Main(string[] args) {
        var asm = Assembly.LoadFrom(args[0]);
        string filter = args.Length > 1 ? args[1] : "";
        foreach (var t in asm.GetTypes()) {
            foreach (var m in t.GetMethods(BindingFlags.Static | BindingFlags.Instance | BindingFlags.Public | BindingFlags.NonPublic | BindingFlags.DeclaredOnly)) {
                if ((m.Attributes & MethodAttributes.PinvokeImpl) == 0) continue;
                if (filter != "" && !(t.FullName + "." + m.Name).Contains(filter)) continue;
                var di = m.GetCustomAttribute<DllImportAttribute>();
                string ps = string.Join(", ", m.GetParameters().Select(p => p.ParameterType.ToString() + (p.IsOut ? " out" : "")));
                Console.WriteLine("{0}.{1} [{2} {3}] : {4} ({5})", t.FullName, m.Name, di != null ? di.Value : "?", di != null ? di.CallingConvention.ToString() : "?", m.ReturnType, ps);
            }
        }
    }
}

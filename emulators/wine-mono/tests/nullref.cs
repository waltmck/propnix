using System;
class N { static void Main() { Console.WriteLine("before"); string s = null; try { Console.WriteLine(s.Length); } catch (NullReferenceException) { Console.WriteLine("caught NRE"); } Console.WriteLine("after"); } }

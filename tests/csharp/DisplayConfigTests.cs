using System;
using System.IO;

static class DisplayConfigTests
{
    static int failures;

    static void Equal(int expected, int actual, string name)
    {
        if (expected != actual) { Console.Error.WriteLine(name + ": expected " + expected + ", actual " + actual); failures++; }
    }

    static void Invalid(string value, string name)
    {
        string path = Path.GetTempFileName();
        try {
            File.WriteAllText(path, value);
            try { DisplayConfig.Load(path); Console.Error.WriteLine(name + ": FormatExceptionにならなかった"); failures++; }
            catch (FormatException) { }
        } finally { File.Delete(path); }
    }

    static void InvalidDirectory(string name)
    {
        string path = Path.Combine(Path.GetTempPath(), Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(path);
        try {
            try { DisplayConfig.Load(path); Console.Error.WriteLine(name + ": FormatExceptionにならなかった"); failures++; }
            catch (FormatException) { }
        } finally { Directory.Delete(path); }
    }

    public static int Main()
    {
        string missing = Path.Combine(Path.GetTempPath(), Guid.NewGuid().ToString("N"));
        DisplayConfig defaults = DisplayConfig.Load(missing);
        Equal(1920, defaults.Width, "既定幅");
        Equal(1080, defaults.Height, "既定高さ");
        Equal(0, defaults.Scale, "既定スケール");

        string valid = Path.GetTempFileName();
        File.WriteAllText(valid, "2800X1272x225\r\n");
        DisplayConfig parsed = DisplayConfig.Load(valid);
        Equal(2800, parsed.Width, "指定幅");
        Equal(1272, parsed.Height, "指定高さ");
        Equal(225, parsed.Scale, "指定スケール");
        File.Delete(valid);

        Invalid("639x1080", "幅下限未満");
        Invalid("1920x8193", "高さ上限超過");
        Invalid("1920x1080x99", "スケール下限未満");
        Invalid("1920x1080x501", "スケール上限超過");
        Invalid("1920x1080x100x1", "余分な項目");
        Invalid("-1920x1080", "負数");
        Invalid("1920.5x1080", "小数");
        Invalid("999999999999x1080", "整数オーバーフロー");
        Invalid("1920x1080 trailing", "末尾文字");
        InvalidDirectory("同名ディレクトリ");
        return failures == 0 ? 0 : 1;
    }
}

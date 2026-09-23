using System;
using System.Globalization;
using System.IO;
using System.Text.RegularExpressions;

public sealed class DisplayConfig
{
    static readonly Regex Pattern = new Regex(@"^(\d+)[xX](\d+)(?:[xX](\d+))?$", RegexOptions.CultureInvariant);
    public int Width { get; private set; }
    public int Height { get; private set; }
    public int Scale { get; private set; }

    DisplayConfig(int width, int height, int scale) { Width = width; Height = height; Scale = scale; }

    public static DisplayConfig Load(string path)
    {
        string text;
        try
        {
            text = File.ReadAllText(path).Trim();
        }
        catch (FileNotFoundException)
        {
            return new DisplayConfig(1920, 1080, 0);
        }
        catch (DirectoryNotFoundException)
        {
            return new DisplayConfig(1920, 1080, 0);
        }
        catch (Exception ex)
        {
            throw new FormatException("display.cfgを読み込めません。", ex);
        }
        Match match = Pattern.Match(text);
        if (!match.Success) throw new FormatException("display.cfgは WIDTHxHEIGHT または WIDTHxHEIGHTxSCALE で指定してください。");
        int width, height, scale = 0;
        if (!Int32.TryParse(match.Groups[1].Value, NumberStyles.None, CultureInfo.InvariantCulture, out width) ||
            !Int32.TryParse(match.Groups[2].Value, NumberStyles.None, CultureInfo.InvariantCulture, out height) ||
            (match.Groups[3].Success && !Int32.TryParse(match.Groups[3].Value, NumberStyles.None, CultureInfo.InvariantCulture, out scale)))
            throw new FormatException("display.cfgに32ビット整数として解釈できない値があります。");
        if (width < 640 || width > 8192 || height < 480 || height > 8192 ||
            (match.Groups[3].Success && (scale < 100 || scale > 500)))
            throw new FormatException("display.cfgの許容範囲は幅640～8192、高さ480～8192、スケール100～500です。");
        return new DisplayConfig(width, height, scale);
    }
}

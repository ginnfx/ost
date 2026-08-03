using Windows.UI;

namespace OstTracker.Themes;

/// <summary>Theme tokens mirroring the macOS app (see clients/THEME.md).</summary>
public static class Theme
{
    public static readonly string AccentDefault = "#20D760";
    public static readonly string[] PresetHexes =
    {
        "#20D760", "#F5A623", "#FF3D81", "#4FC3F7", "#8A54D0", "#FF6B4A",
    };

    public static readonly string Gold = "#F2B705";
    public static readonly string Pink = "#FF3D81";
    public static readonly string Rust = "#E8541E";

    public static readonly string Bg = "#101014";
    public static readonly string BgRaised = "#18181E";
    public static readonly string CardSurface = "#1C1C24";
    public static readonly string TextPrimary = "#F5F2EA";
    public static readonly string TextDim = "#9B97A8";

    /// <summary>Parse "#RRGGBB" → Color, falling back to the default accent.</summary>
    public static Color ParseHex(string? hex)
    {
        if (hex is null or { Length: != 7 } || !hex.StartsWith("#"))
            return ParseHex(AccentDefault);
        byte r = Convert.ToByte(hex.Substring(1, 2), 16);
        byte g = Convert.ToByte(hex.Substring(3, 2), 16);
        byte b = Convert.ToByte(hex.Substring(5, 2), 16);
        return Color.FromArgb(255, r, g, b);
    }
}

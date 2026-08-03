using Microsoft.UI.Xaml.Media.Imaging;
using Windows.Storage.Streams;

namespace OstTracker.Themes;

/// <summary>Off-thread, downsampled cover loading from the local file path.</summary>
public static class CoverLoader
{
    /// <summary>Load a cover as a BitmapImage (decodes at ~300px, off the UI thread).</summary>
    public static async Task<BitmapImage?> LoadAsync(string? path)
    {
        if (string.IsNullOrEmpty(path) || !File.Exists(path)) return null;
        try
        {
            var bitmap = new BitmapImage { DecodePixelWidth = 300 };
            using var stream = File.OpenRead(path);
            using var ras = stream.AsRandomAccessStream();
            await bitmap.SetSourceAsync(ras);
            return bitmap;
        }
        catch (Exception)
        {
            return null;
        }
    }

    /// <summary>Neutral placeholder for missing covers.</summary>
    public static BitmapImage Placeholder()
    {
        // A 1x1 transparent pixel scaled up — the card border carries the look.
        var bmp = new BitmapImage();
        var bytes = new byte[] { 0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A };
        using var ms = new MemoryStream(bytes);
        using var ras = ms.AsRandomAccessStream();
        bmp.SetSource(ras);
        return bmp;
    }
}

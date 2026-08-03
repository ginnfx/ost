using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace OstTracker.Views;

/// <summary>Small code-built-UI helpers so pages stay compact.</summary>
public static class Ui
{
    public static TextBlock Title(string text) => new()
    {
        Text = text,
        FontSize = 22,
        FontWeight = FontWeights.SemiBold,
    };

    public static StackPanel Stack(string? header = null, UIElement? body = null, params UIElement[] extras)
    {
        var panel = new StackPanel { Spacing = 8, Margin = new Thickness(16) };
        if (header != null) panel.Children.Add(Title(header));
        if (body != null) panel.Children.Add(body);
        foreach (var extra in extras) panel.Children.Add(extra);
        return panel;
    }

    public static ListView StringList(string emptyText)
    {
        var list = new ListView { SelectionMode = ListViewSelectionMode.None };
        list.ItemsSource = new[] { emptyText };
        return list;
    }

    public static void SetStatus(Page page, string message)
    {
        if (page.Content is StackPanel sp && sp.Children.Count > 0 && sp.Children[^1] is TextBlock tb && tb.Tag is null)
            tb.Text = message;
    }

    public static Button Button(string label) => new() { Content = label };
}

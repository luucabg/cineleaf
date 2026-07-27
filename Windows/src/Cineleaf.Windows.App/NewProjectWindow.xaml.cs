using System.Windows;
using System.Windows.Controls;
using Cineleaf.Core;

namespace Cineleaf.Windows;

public partial class NewProjectWindow : Window
{
    public NewProjectWindow() => InitializeComponent();
    public NewProjectWindow(CineleafProject project) : this()
    {
        Title = FindResource("ProjectSettings").ToString();
        Heading.Text = Title;
        SubmitButton.Content = FindResource("Apply");
        NameBox.Text = project.Name;
        Select(CanvasBox, project.CanvasPreset.ToString());
        Select(FrameRateBox, project.FrameRate.ToString());
    }
    public string ProjectName => NameBox.Text;
    public CanvasPreset Canvas => Parse<CanvasPreset>(CanvasBox);
    public ProjectFrameRate FrameRate => Parse<ProjectFrameRate>(FrameRateBox);
    private void Create_Click(object sender, RoutedEventArgs e) { DialogResult = true; Close(); }
    private void Cancel_Click(object sender, RoutedEventArgs e) { DialogResult = false; Close(); }
    private static T Parse<T>(ComboBox box) where T : struct, Enum =>
        box.SelectedItem is ComboBoxItem { Tag: string value } && Enum.TryParse<T>(value, out var result) ? result : default;
    private static void Select(ComboBox box, string value) => box.SelectedItem = box.Items.OfType<ComboBoxItem>()
        .FirstOrDefault(item => string.Equals(item.Tag?.ToString(), value, StringComparison.OrdinalIgnoreCase));
}

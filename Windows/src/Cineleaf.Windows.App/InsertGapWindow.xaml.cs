using System.Globalization;
using System.Windows;

namespace Cineleaf.Windows;

public partial class InsertGapWindow : Window
{
    public InsertGapWindow() => InitializeComponent();
    public double DurationSeconds { get; private set; } = 1;

    private void Insert_Click(object sender, RoutedEventArgs e)
    {
        if (!double.TryParse(DurationBox.Text, NumberStyles.Float, CultureInfo.CurrentCulture, out var value) ||
            !double.IsFinite(value) || value <= 0 || value > 86_400)
        {
            MessageBox.Show(this, FindResource("GapInvalid").ToString(), FindResource("ErrorTitle").ToString(), MessageBoxButton.OK, MessageBoxImage.Warning);
            return;
        }
        DurationSeconds = value;
        DialogResult = true;
        Close();
    }

    private void Cancel_Click(object sender, RoutedEventArgs e) { DialogResult = false; Close(); }
}

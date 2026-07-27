using System.ComponentModel;
using System.Globalization;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Threading;
using Cineleaf.Core;
using Cineleaf.Media;
using Microsoft.Win32;

namespace Cineleaf.Windows;

public partial class MainWindow : Window, IDisposable
{
    private readonly EditorViewModel _viewModel;
    private readonly DispatcherTimer _playbackTimer;
    private readonly DispatcherTimer _autosaveTimer;
    private bool _isPlaying;
    private bool _isClosingAfterSave;
    private bool _sliderUpdate;
    private bool _disposed;
    private Point _mediaDragStart;

    public MainWindow()
    {
        InitializeComponent();
        _viewModel = new EditorViewModel();
        DataContext = _viewModel;
        MediaList.ItemsSource = _viewModel.Assets;
        _viewModel.ProjectChanged += (_, _) => Dispatcher.Invoke(RefreshProject);
        _viewModel.PreviewReady += (_, path) => Dispatcher.Invoke(() => LoadPreview(path));
        _viewModel.Error += (_, error) => Dispatcher.Invoke(() => ShowError(error));
        _viewModel.StatusChanged += (_, key) => Dispatcher.Invoke(() => StatusText.Text = FindResource(key)?.ToString() ?? key);
        _viewModel.ProgressChanged += (_, value) => Dispatcher.Invoke(() =>
        {
            WorkProgress.Visibility = Visibility.Visible;
            WorkProgress.Value = value;
            if (value >= 1) WorkProgress.Visibility = Visibility.Collapsed;
        });
        _playbackTimer = new DispatcherTimer(TimeSpan.FromMilliseconds(100), DispatcherPriority.Background, PlaybackTimer_Tick, Dispatcher);
        _autosaveTimer = new DispatcherTimer(TimeSpan.FromSeconds(5), DispatcherPriority.Background, AutosaveTimer_Tick, Dispatcher);
        _playbackTimer.Start();
        _autosaveTimer.Start();
        SelectLanguageBox();
        RefreshProject();
    }

    public async Task OpenFromCommandLineAsync(string path)
    {
        try { await _viewModel.OpenAsync(path); }
        catch (Exception error) { ShowError(error); }
    }

    private void RefreshProject()
    {
        Title = $"{_viewModel.Project.Name}{(_viewModel.IsDirty ? " •" : string.Empty)} — Cineleaf";
        Timeline.Playhead = _viewModel.Playhead;
        Timeline.SetProject(_viewModel.Project, _viewModel.SelectedClipId);
        var clip = _viewModel.SelectedClip;
        NoSelectionText.Visibility = clip is null ? Visibility.Visible : Visibility.Collapsed;
        InspectorPanel.Visibility = clip is null ? Visibility.Collapsed : Visibility.Visible;
        if (clip is null) return;
        ClipNameBox.Text = clip.Name;
        StartBox.Text = Format(clip.TimelineStart.Seconds);
        DurationBox.Text = Format(clip.Duration.Seconds);
        SpeedBox.Text = Format(clip.PlaybackRate);
        OpacityBox.Text = Format(clip.Opacity);
        VolumeBox.Text = Format(clip.AudioVolume);
        ScaleBox.Text = Format(clip.Transform.Scale);
        RotationBox.Text = Format(clip.Transform.RotationDegrees);
        SelectTag(ContentModeBox, clip.Transform.ContentMode.ToString());
        EnabledBox.IsChecked = clip.IsEnabled;
        ReverseBox.IsChecked = clip.IsReversed;
        HideVideoBox.IsChecked = clip.IsVideoMuted;
        FadeInBox.Text = Format(Math.Max(clip.Fades.VideoIn.Seconds, clip.Fades.AudioIn.Seconds));
        FadeOutBox.Text = Format(Math.Max(clip.Fades.VideoOut.Seconds, clip.Fades.AudioOut.Seconds));
        CropTopBox.Text = Format(clip.Transform.CropTop);
        CropBottomBox.Text = Format(clip.Transform.CropBottom);
        CropLeftBox.Text = Format(clip.Transform.CropLeading);
        CropRightBox.Text = Format(clip.Transform.CropTrailing);
        SelectTag(TransitionInBox, clip.TransitionIn?.Kind.ToString() ?? "None");
        SelectTag(TransitionOutBox, clip.TransitionOut?.Kind.ToString() ?? "None");
        TextContentBox.Text = clip.TextStyle?.Text ?? string.Empty;
        TextContentBox.IsEnabled = clip.TextStyle is not null;
    }

    private void LoadPreview(string path)
    {
        PreviewPlayer.Stop();
        PreviewPlayer.Source = new Uri(path, UriKind.Absolute);
        PreviewEmpty.Visibility = Visibility.Collapsed;
        PreviewPlayer.Position = TimeSpan.FromSeconds(_viewModel.Playhead.Seconds);
    }

    private void New_Click(object sender, RoutedEventArgs e)
    {
        var dialog = new NewProjectWindow { Owner = this };
        if (dialog.ShowDialog() == true) _viewModel.NewProject(dialog.ProjectName, dialog.Canvas, dialog.FrameRate);
    }

    private void ProjectSettings_Click(object sender, RoutedEventArgs e)
    {
        var dialog = new NewProjectWindow(_viewModel.Project) { Owner = this };
        if (dialog.ShowDialog() == true)
            RunEdit(() => _viewModel.UpdateProjectSettings(dialog.ProjectName, dialog.Canvas, dialog.FrameRate));
    }

    private async void Open_Click(object sender, RoutedEventArgs e)
    {
        var dialog = new OpenFolderDialog { Title = FindResource("Open").ToString(), Multiselect = false };
        if (dialog.ShowDialog(this) != true) return;
        try { await _viewModel.OpenAsync(dialog.FolderName); }
        catch (Exception error) { ShowError(error); }
    }

    private async void Save_Click(object sender, RoutedEventArgs e) => await SaveWithDialogAsync();

    private async Task<bool> SaveWithDialogAsync()
    {
        var path = _viewModel.ProjectPath;
        if (path is null)
        {
            var dialog = new SaveFileDialog
            {
                Title = FindResource("Save").ToString(),
                Filter = "Cineleaf project folder (*.cineleaf)|*.cineleaf",
                FileName = SanitizeName(_viewModel.Project.Name) + ".cineleaf",
                AddExtension = true
            };
            if (dialog.ShowDialog(this) != true) return false;
            path = dialog.FileName;
        }
        try { await _viewModel.SaveAsync(path); RefreshProject(); return true; }
        catch (Exception error) { ShowError(error); return false; }
    }

    private async void Import_Click(object sender, RoutedEventArgs e)
    {
        var dialog = new OpenFileDialog
        {
            Title = FindResource("Import").ToString(),
            Multiselect = true,
            Filter = "Media|*.mp4;*.mov;*.mkv;*.avi;*.webm;*.mp3;*.wav;*.m4a;*.aac;*.flac;*.png;*.jpg;*.jpeg;*.webp;*.bmp;*.tif;*.tiff|All files|*.*"
        };
        if (dialog.ShowDialog(this) != true) return;
        try { await _viewModel.ImportAsync(dialog.FileNames); }
        catch (Exception error) { ShowError(error); }
    }

    private void Undo_Click(object sender, RoutedEventArgs e) => _viewModel.Undo();
    private void Redo_Click(object sender, RoutedEventArgs e) => _viewModel.Redo();
    private void Split_Click(object sender, RoutedEventArgs e) => RunEdit(_viewModel.SplitSelected);
    private void AddText_Click(object sender, RoutedEventArgs e) => RunEdit(() => _viewModel.AddText());
    private void Duplicate_Click(object sender, RoutedEventArgs e) => RunEdit(_viewModel.DuplicateSelected);
    private void DetachAudio_Click(object sender, RoutedEventArgs e) => RunEdit(_viewModel.DetachSelectedAudio);
    private void InsertGap_Click(object sender, RoutedEventArgs e)
    {
        var dialog = new InsertGapWindow { Owner = this };
        if (dialog.ShowDialog() == true) RunEdit(() => _viewModel.InsertGap(dialog.DurationSeconds));
    }
    private void RippleDelete_Click(object sender, RoutedEventArgs e) => RunEdit(() => _viewModel.DeleteSelected(ripple: true));
    private void Marker_Click(object sender, RoutedEventArgs e) => RunEdit(_viewModel.AddMarker);

    private async void ExtractAudio_Click(object sender, RoutedEventArgs e)
    {
        var clip = _viewModel.SelectedClip;
        var dialog = new SaveFileDialog
        {
            Title = FindResource("ExtractAudio").ToString(),
            Filter = "M4A audio (*.m4a)|*.m4a",
            FileName = SanitizeName(clip?.Name ?? "audio") + ".m4a",
            AddExtension = true
        };
        if (dialog.ShowDialog(this) != true) return;
        try
        {
            await _viewModel.ExtractSelectedAudioAsync(dialog.FileName);
            StatusText.Text = FindResource("AudioExtracted").ToString();
        }
        catch (Exception error) { ShowError(error); }
    }

    private async void SaveFrame_Click(object sender, RoutedEventArgs e)
    {
        var dialog = new SaveFileDialog
        {
            Title = FindResource("SaveFrame").ToString(),
            Filter = "PNG image (*.png)|*.png",
            FileName = SanitizeName(_viewModel.SelectedClip?.Name ?? "frame") + ".png",
            AddExtension = true
        };
        if (dialog.ShowDialog(this) != true) return;
        try
        {
            await _viewModel.ExtractCurrentFrameAsync(dialog.FileName);
            StatusText.Text = FindResource("FrameSaved").ToString();
        }
        catch (Exception error) { ShowError(error); }
    }

    private async void FindBeats_Click(object sender, RoutedEventArgs e)
    {
        try
        {
            var count = await _viewModel.FindBeatsAsync();
            StatusText.Text = $"{count} beat markers";
        }
        catch (Exception error) { ShowError(error); }
    }

    private async void RemoveSilence_Click(object sender, RoutedEventArgs e)
    {
        try
        {
            var ranges = await _viewModel.DetectSilenceAsync();
            if (ranges.Count == 0) { StatusText.Text = "No long silent ranges found."; return; }
            var seconds = ranges.Sum(range => range.Duration.Seconds);
            var answer = MessageBox.Show(this,
                $"Cineleaf found {ranges.Count} silent ranges ({seconds:0.0} seconds). Remove them from every unlocked track? You can undo this.",
                FindResource("RemoveSilence").ToString(), MessageBoxButton.YesNo, MessageBoxImage.Question);
            if (answer == MessageBoxResult.Yes) _viewModel.RemoveSilence(ranges);
        }
        catch (Exception error) { ShowError(error); }
    }

    private async void Captions_Click(object sender, RoutedEventArgs e)
    {
        try
        {
            var available = OnDeviceCaptionService.AvailableCultures;
            if (available.Count == 0) throw new InvalidOperationException("Windows has no offline speech language installed. Add one in Settings → Time & language → Speech.");
            var preferred = available.FirstOrDefault(culture => culture.TwoLetterISOLanguageName == CultureInfo.CurrentUICulture.TwoLetterISOLanguageName) ?? available[0];
            await _viewModel.GenerateCaptionsAsync(preferred);
        }
        catch (Exception error) { ShowError(error); }
    }

    private void ImportSubtitles_Click(object sender, RoutedEventArgs e)
    {
        var dialog = new OpenFileDialog { Filter = "Subtitles|*.srt;*.vtt", Multiselect = false };
        if (dialog.ShowDialog(this) != true) return;
        try
        {
            var format = Path.GetExtension(dialog.FileName).Equals(".vtt", StringComparison.OrdinalIgnoreCase) ? SubtitleFormat.WebVtt : SubtitleFormat.Srt;
            _viewModel.ImportSubtitles(File.ReadAllText(dialog.FileName), format);
        }
        catch (Exception error) { ShowError(error); }
    }

    private void Export_Click(object sender, RoutedEventArgs e)
    {
        if (_viewModel.Project.Timeline.Duration <= RationalTime.Zero) { ShowError(new InvalidOperationException("Add at least one clip before exporting.")); return; }
        new ExportWindow(_viewModel) { Owner = this }.ShowDialog();
    }

    private void MediaList_MouseDoubleClick(object sender, MouseButtonEventArgs e)
    {
        if (MediaList.SelectedItem is MediaAsset asset) RunEdit(() => _viewModel.AddAssetToTimeline(asset.Id));
    }

    private void MediaList_SelectionChanged(object sender, SelectionChangedEventArgs e) => _viewModel.SelectedAsset = MediaList.SelectedItem as MediaAsset;

    private void MediaList_PreviewMouseMove(object sender, MouseEventArgs e)
    {
        if (e.LeftButton == MouseButtonState.Pressed && MediaList.SelectedItem is MediaAsset asset &&
            (e.GetPosition(MediaList) - _mediaDragStart).Length > SystemParameters.MinimumHorizontalDragDistance)
            DragDrop.DoDragDrop(MediaList, new DataObject("CineleafAsset", asset.Id.ToString()), DragDropEffects.Copy);
        else if (e.LeftButton == MouseButtonState.Released) _mediaDragStart = e.GetPosition(MediaList);
    }

    private void MediaList_PreviewMouseLeftButtonDown(object sender, MouseButtonEventArgs e) =>
        _mediaDragStart = e.GetPosition(MediaList);

    private void Timeline_ClipSelected(object sender, ClipSelectedEventArgs e) => _viewModel.SelectClip(e.ClipId);
    private void Timeline_ClipMoveRequested(object sender, ClipMoveRequestedEventArgs e) => RunEdit(() => { _viewModel.SelectClip(e.ClipId); _viewModel.MoveSelected(e.Start); });
    private void Timeline_AssetDropped(object sender, AssetDroppedEventArgs e) => RunEdit(() => _viewModel.AddAssetToTimeline(e.AssetId, e.TrackId, e.Start));

    private void ApplyInspector_Click(object sender, RoutedEventArgs e)
    {
        try
        {
            _viewModel.ApplySelectedClip(ClipNameBox.Text, Parse(StartBox), Parse(DurationBox), Parse(SpeedBox),
                Parse(OpacityBox), Parse(VolumeBox), Parse(ScaleBox), Parse(RotationBox), TextContentBox.Text,
                ParseEnum<ContentMode>(ContentModeBox), EnabledBox.IsChecked == true, ReverseBox.IsChecked == true,
                HideVideoBox.IsChecked == true, Parse(FadeInBox), Parse(FadeOutBox), Parse(CropTopBox),
                Parse(CropBottomBox), Parse(CropLeftBox), Parse(CropRightBox), ParseTransition(TransitionInBox),
                ParseTransition(TransitionOutBox));
        }
        catch (Exception error) { ShowError(error); }
    }

    private void AddEffect_Click(object sender, RoutedEventArgs e)
    {
        if (EffectBox.SelectedItem is ComboBoxItem { Tag: string value } && Enum.TryParse<VideoEffectKind>(value, out var kind))
            RunEdit(() => _viewModel.AddEffect(kind));
    }

    private void Play_Click(object sender, RoutedEventArgs e)
    {
        if (PreviewPlayer.Source is null) { _viewModel.RequestPreview(); return; }
        if (_isPlaying) PreviewPlayer.Pause(); else PreviewPlayer.Play();
        _isPlaying = !_isPlaying;
    }

    private void PreviewPlayer_MediaOpened(object sender, RoutedEventArgs e)
    {
        if (PreviewPlayer.NaturalDuration.HasTimeSpan) PreviewSlider.Maximum = PreviewPlayer.NaturalDuration.TimeSpan.TotalSeconds;
    }

    private void PreviewPlayer_MediaEnded(object sender, RoutedEventArgs e) { _isPlaying = false; PreviewPlayer.Position = TimeSpan.Zero; }

    private void PreviewSlider_ValueChanged(object sender, RoutedPropertyChangedEventArgs<double> e)
    {
        if (_sliderUpdate || !PreviewPlayer.NaturalDuration.HasTimeSpan) return;
        PreviewPlayer.Position = TimeSpan.FromSeconds(e.NewValue);
        _viewModel.Playhead = RationalTime.FromSeconds(e.NewValue);
        Timeline.Playhead = _viewModel.Playhead;
        Timeline.InvalidateVisual();
    }

    private void PlaybackTimer_Tick(object? sender, EventArgs e)
    {
        if (PreviewPlayer.Source is null) return;
        _sliderUpdate = true;
        PreviewSlider.Value = PreviewPlayer.Position.TotalSeconds;
        _sliderUpdate = false;
        _viewModel.Playhead = RationalTime.FromSeconds(PreviewPlayer.Position.TotalSeconds);
        Timeline.Playhead = _viewModel.Playhead;
        Timeline.InvalidateVisual();
        var total = PreviewPlayer.NaturalDuration.HasTimeSpan ? PreviewPlayer.NaturalDuration.TimeSpan : TimeSpan.Zero;
        TimeText.Text = $"{FormatTime(PreviewPlayer.Position)} / {FormatTime(total)}";
    }

    private async void AutosaveTimer_Tick(object? sender, EventArgs e)
    {
        try { await _viewModel.AutosaveAsync(); }
        catch (Exception error) { StatusText.Text = error.Message; }
    }

    private void LanguageBox_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (LanguageBox.SelectedItem is not ComboBoxItem { Tag: string language }) return;
        LocalizationService.Apply(language);
        RefreshProject();
    }

    private void SelectLanguageBox()
    {
        foreach (var item in LanguageBox.Items.OfType<ComboBoxItem>())
            if (Equals(item.Tag, LocalizationService.Preference)) { LanguageBox.SelectedItem = item; break; }
    }

    private void Window_KeyDown(object sender, KeyEventArgs e)
    {
        var control = (Keyboard.Modifiers & ModifierKeys.Control) != 0;
        var shift = (Keyboard.Modifiers & ModifierKeys.Shift) != 0;
        var alt = (Keyboard.Modifiers & ModifierKeys.Alt) != 0;
        if (e.Key == Key.Space) { Play_Click(sender, e); e.Handled = true; }
        else if (control && e.Key == Key.N) { New_Click(sender, e); e.Handled = true; }
        else if (control && e.Key == Key.O) { Open_Click(sender, e); e.Handled = true; }
        else if (control && e.Key == Key.S) { Save_Click(sender, e); e.Handled = true; }
        else if (control && e.Key == Key.I) { Import_Click(sender, e); e.Handled = true; }
        else if (control && e.Key == Key.E) { Export_Click(sender, e); e.Handled = true; }
        else if (control && e.Key == Key.B) { Split_Click(sender, e); e.Handled = true; }
        else if (control && !alt && e.Key == Key.D) { Duplicate_Click(sender, e); e.Handled = true; }
        else if (control && alt && e.Key == Key.G) { InsertGap_Click(sender, e); e.Handled = true; }
        else if (control && alt && e.Key == Key.A) { DetachAudio_Click(sender, e); e.Handled = true; }
        else if (control && e.Key == Key.Z && !shift) { _viewModel.Undo(); e.Handled = true; }
        else if ((control && e.Key == Key.Y) || (control && shift && e.Key == Key.Z)) { _viewModel.Redo(); e.Handled = true; }
        else if (e.Key == Key.Delete) { RunEdit(() => _viewModel.DeleteSelected(ripple: false)); e.Handled = true; }
        else if (e.Key == Key.M && Keyboard.Modifiers == ModifierKeys.None) { _viewModel.AddMarker(); e.Handled = true; }
        else if (control && (e.Key == Key.Add || e.Key == Key.OemPlus)) { Timeline.Zoom(1.2); e.Handled = true; }
        else if (control && (e.Key == Key.Subtract || e.Key == Key.OemMinus)) { Timeline.Zoom(1 / 1.2); e.Handled = true; }
        else if (e.Key is Key.Left or Key.Right)
        {
            var step = shift ? 1d : 1d / 30;
            _viewModel.Playhead = RationalTime.FromSeconds(Math.Max(0, _viewModel.Playhead.Seconds + (e.Key == Key.Right ? step : -step)));
            PreviewPlayer.Position = TimeSpan.FromSeconds(_viewModel.Playhead.Seconds); e.Handled = true;
        }
        else if (e.Key == Key.Home) { _viewModel.Playhead = RationalTime.Zero; PreviewPlayer.Position = TimeSpan.Zero; e.Handled = true; }
        else if (e.Key == Key.End) { _viewModel.Playhead = _viewModel.Project.Timeline.Duration; PreviewPlayer.Position = TimeSpan.FromSeconds(_viewModel.Playhead.Seconds); e.Handled = true; }
    }

    private async void Window_Closing(object? sender, CancelEventArgs e)
    {
        if (_isClosingAfterSave || !_viewModel.IsDirty) { Dispose(); return; }
        var result = MessageBox.Show(this, "Save this project before closing?", "Cineleaf", MessageBoxButton.YesNoCancel, MessageBoxImage.Question);
        if (result == MessageBoxResult.Cancel) { e.Cancel = true; return; }
        if (result == MessageBoxResult.No) { Dispose(); return; }
        e.Cancel = true;
        if (await SaveWithDialogAsync()) { _isClosingAfterSave = true; Close(); }
    }

    private void RunEdit(Action edit)
    {
        try { edit(); }
        catch (Exception error) { ShowError(error); }
    }

    private void ShowError(Exception error) => MessageBox.Show(this, error.Message, FindResource("ErrorTitle").ToString(), MessageBoxButton.OK, MessageBoxImage.Error);
    private static string Format(double number) => number.ToString("0.###", CultureInfo.CurrentCulture);
    private static T ParseEnum<T>(ComboBox box) where T : struct, Enum =>
        box.SelectedItem is ComboBoxItem { Tag: string value } && Enum.TryParse<T>(value, out var result) ? result : default;
    private static TransitionKind? ParseTransition(ComboBox box) =>
        box.SelectedItem is ComboBoxItem { Tag: string value } && !value.Equals("None", StringComparison.OrdinalIgnoreCase) &&
        Enum.TryParse<TransitionKind>(value, out var result) ? result : null;
    private static void SelectTag(ComboBox box, string value) => box.SelectedItem = box.Items.OfType<ComboBoxItem>()
        .FirstOrDefault(item => string.Equals(item.Tag?.ToString(), value, StringComparison.OrdinalIgnoreCase));
    private static double Parse(TextBox box) => double.TryParse(box.Text, NumberStyles.Float, CultureInfo.CurrentCulture, out var value)
        ? value : throw new FormatException($"“{box.Text}” is not a valid number.");
    private static string FormatTime(TimeSpan time) => time.ToString(time.TotalHours >= 1 ? @"h\:mm\:ss" : @"m\:ss", CultureInfo.CurrentCulture);
    private static string SanitizeName(string value) => string.Concat(value.Select(character => Path.GetInvalidFileNameChars().Contains(character) ? '-' : character)).Trim();

    public void Dispose()
    {
        if (_disposed) return;
        _disposed = true;
        _playbackTimer.Stop();
        _autosaveTimer.Stop();
        _viewModel.Dispose();
        GC.SuppressFinalize(this);
    }
}

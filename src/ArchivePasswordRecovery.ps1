#requires -Version 5.1
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Show-StartupFailure {
    param([Parameter(Mandatory = $true)]$ErrorRecord)

    $detail = [string]$ErrorRecord.Exception.Message
    if ([string]::IsNullOrWhiteSpace($detail)) { $detail = '图形界面初始化失败。' }
    if ($detail.Length -gt 240) { $detail = $detail.Substring(0, 240) }
    try {
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction SilentlyContinue
        [System.Windows.Forms.MessageBox]::Show(
            ('程序启动失败。' + [Environment]::NewLine + $detail),
            '压缩包密码恢复',
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error
        ) | Out-Null
    }
    catch { }
}

trap {
    Show-StartupFailure -ErrorRecord $_
    exit 1
}

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Windows.Forms
Import-Module (Join-Path $PSScriptRoot 'RecoveryCore.psm1') -Force -DisableNameChecking

$projectRoot = Split-Path $PSScriptRoot -Parent
$jobsRoot = Join-Path $env:LOCALAPPDATA 'ArchivePasswordRecovery\Jobs'
New-Item -ItemType Directory -Path $jobsRoot -Force | Out-Null
$runtimeRoot = Get-RecoveryRuntimeRoot
New-Item -ItemType Directory -Path $runtimeRoot -Force | Out-Null

[xml]$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="压缩包密码恢复"
        Width="980" Height="900" MinWidth="820" MinHeight="700"
        WindowStartupLocation="CenterScreen" Background="#F6F8FB" AllowDrop="True"
        FontFamily="Segoe UI" UseLayoutRounding="True" SnapsToDevicePixels="True">
    <Window.Resources>
        <SolidColorBrush x:Key="SurfaceBrush" Color="#FFFFFF" />
        <SolidColorBrush x:Key="SurfaceSubtleBrush" Color="#FBFCFE" />
        <SolidColorBrush x:Key="SurfaceHoverBrush" Color="#F8FBFF" />
        <SolidColorBrush x:Key="SurfacePressedBrush" Color="#EEF5FF" />
        <SolidColorBrush x:Key="PrimaryBrush" Color="#2F75C9" />
        <SolidColorBrush x:Key="PrimaryHoverBrush" Color="#2468BA" />
        <SolidColorBrush x:Key="PrimaryPressedBrush" Color="#1E5DAA" />
        <SolidColorBrush x:Key="PrimarySoftBrush" Color="#EDF5FF" />
        <SolidColorBrush x:Key="BorderBrush" Color="#DFE6EE" />
        <SolidColorBrush x:Key="BorderStrongBrush" Color="#C9D8E8" />
        <SolidColorBrush x:Key="DropZoneBorderBrush" Color="#78A9E7" />
        <SolidColorBrush x:Key="DividerBrush" Color="#E7EDF4" />
        <SolidColorBrush x:Key="TextStrongBrush" Color="#1D2A3A" />
        <SolidColorBrush x:Key="TextBodyBrush" Color="#33465B" />
        <SolidColorBrush x:Key="TextMutedBrush" Color="#6D7E92" />
        <SolidColorBrush x:Key="TextFaintBrush" Color="#8A99AA" />
        <SolidColorBrush x:Key="SuccessSurfaceBrush" Color="#EFF9F1" />
        <SolidColorBrush x:Key="SuccessBorderBrush" Color="#A8D5B0" />
        <SolidColorBrush x:Key="SuccessTextBrush" Color="#237A36" />
        <CornerRadius x:Key="CardCornerRadius">10</CornerRadius>
        <CornerRadius x:Key="ControlCornerRadius">7</CornerRadius>

        <Style x:Key="CardStyle" TargetType="{x:Type Border}">
            <Setter Property="Background" Value="{StaticResource SurfaceBrush}" />
            <Setter Property="BorderBrush" Value="{StaticResource BorderBrush}" />
            <Setter Property="BorderThickness" Value="1" />
            <Setter Property="CornerRadius" Value="{StaticResource CardCornerRadius}" />
            <Setter Property="Padding" Value="18" />
        </Style>
        <Style x:Key="SectionTitleStyle" TargetType="{x:Type TextBlock}">
            <Setter Property="FontSize" Value="17" />
            <Setter Property="FontWeight" Value="SemiBold" />
            <Setter Property="Foreground" Value="{StaticResource TextStrongBrush}" />
        </Style>
        <Style x:Key="PageTitleStyle" TargetType="{x:Type TextBlock}">
            <Setter Property="FontSize" Value="27" />
            <Setter Property="FontWeight" Value="SemiBold" />
            <Setter Property="Foreground" Value="{StaticResource TextStrongBrush}" />
        </Style>
        <Style x:Key="SubtitleStyle" TargetType="{x:Type TextBlock}">
            <Setter Property="FontSize" Value="13" />
            <Setter Property="Foreground" Value="{StaticResource TextMutedBrush}" />
        </Style>
        <Style x:Key="HelperTextStyle" TargetType="{x:Type TextBlock}">
            <Setter Property="FontSize" Value="12" />
            <Setter Property="Foreground" Value="{StaticResource TextMutedBrush}" />
        </Style>
        <Style x:Key="DetailLabelStyle" TargetType="{x:Type TextBlock}">
            <Setter Property="FontSize" Value="12" />
            <Setter Property="Foreground" Value="{StaticResource TextMutedBrush}" />
        </Style>
        <Style x:Key="DetailValueStyle" TargetType="{x:Type TextBlock}">
            <Setter Property="FontSize" Value="15" />
            <Setter Property="Foreground" Value="{StaticResource TextBodyBrush}" />
        </Style>
        <Style x:Key="KpiLabelStyle" TargetType="{x:Type TextBlock}">
            <Setter Property="FontSize" Value="12" />
            <Setter Property="Foreground" Value="{StaticResource TextMutedBrush}" />
        </Style>
        <Style x:Key="KpiValueStyle" TargetType="{x:Type TextBlock}">
            <Setter Property="FontSize" Value="22" />
            <Setter Property="FontWeight" Value="SemiBold" />
            <Setter Property="Foreground" Value="#173B62" />
        </Style>
        <Style x:Key="BadgeStyle" TargetType="{x:Type Border}">
            <Setter Property="Background" Value="{StaticResource PrimarySoftBrush}" />
            <Setter Property="BorderBrush" Value="#C8DDF7" />
            <Setter Property="BorderThickness" Value="1" />
            <Setter Property="CornerRadius" Value="5" />
            <Setter Property="Padding" Value="8,3" />
        </Style>

        <Style x:Key="ButtonBaseStyle" TargetType="{x:Type Button}">
            <Setter Property="Padding" Value="14,8" />
            <Setter Property="MinHeight" Value="34" />
            <Setter Property="FontSize" Value="13" />
            <Setter Property="FontWeight" Value="SemiBold" />
            <Setter Property="Foreground" Value="{StaticResource TextBodyBrush}" />
            <Setter Property="Background" Value="{StaticResource SurfaceBrush}" />
            <Setter Property="BorderBrush" Value="{StaticResource BorderStrongBrush}" />
            <Setter Property="BorderThickness" Value="1" />
            <Setter Property="HorizontalContentAlignment" Value="Center" />
            <Setter Property="VerticalContentAlignment" Value="Center" />
            <Setter Property="FocusVisualStyle" Value="{x:Null}" />
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="{x:Type Button}">
                        <Border Background="{TemplateBinding Background}"
                                BorderBrush="{TemplateBinding BorderBrush}"
                                BorderThickness="{TemplateBinding BorderThickness}"
                                CornerRadius="{StaticResource ControlCornerRadius}"
                                Padding="{TemplateBinding Padding}">
                            <ContentPresenter HorizontalAlignment="{TemplateBinding HorizontalContentAlignment}"
                                              VerticalAlignment="{TemplateBinding VerticalContentAlignment}"
                                              RecognizesAccessKey="True" />
                        </Border>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
        <Style TargetType="{x:Type Button}" BasedOn="{StaticResource ButtonBaseStyle}">
            <Style.Triggers>
                <Trigger Property="IsMouseOver" Value="True">
                    <Setter Property="Background" Value="{StaticResource SurfaceHoverBrush}" />
                    <Setter Property="BorderBrush" Value="{StaticResource DropZoneBorderBrush}" />
                </Trigger>
                <Trigger Property="IsPressed" Value="True">
                    <Setter Property="Background" Value="{StaticResource SurfacePressedBrush}" />
                    <Setter Property="BorderBrush" Value="{StaticResource PrimaryBrush}" />
                </Trigger>
                <Trigger Property="IsEnabled" Value="False">
                    <Setter Property="Background" Value="#F3F5F8" />
                    <Setter Property="BorderBrush" Value="#E3E8EE" />
                    <Setter Property="Foreground" Value="#A4AFBC" />
                </Trigger>
            </Style.Triggers>
        </Style>
        <Style x:Key="PrimaryButtonStyle" TargetType="{x:Type Button}" BasedOn="{StaticResource ButtonBaseStyle}">
            <Setter Property="Background" Value="{StaticResource PrimaryBrush}" />
            <Setter Property="Foreground" Value="White" />
            <Setter Property="BorderBrush" Value="{StaticResource PrimaryBrush}" />
            <Setter Property="BorderThickness" Value="1" />
            <Setter Property="Padding" Value="24,10" />
            <Style.Triggers>
                <Trigger Property="IsMouseOver" Value="True">
                    <Setter Property="Background" Value="{StaticResource PrimaryHoverBrush}" />
                    <Setter Property="BorderBrush" Value="{StaticResource PrimaryHoverBrush}" />
                </Trigger>
                <Trigger Property="IsPressed" Value="True">
                    <Setter Property="Background" Value="{StaticResource PrimaryPressedBrush}" />
                    <Setter Property="BorderBrush" Value="{StaticResource PrimaryPressedBrush}" />
                </Trigger>
                <Trigger Property="IsEnabled" Value="False">
                    <Setter Property="Background" Value="#B8CCE5" />
                    <Setter Property="BorderBrush" Value="#B8CCE5" />
                    <Setter Property="Foreground" Value="#EDF3FA" />
                </Trigger>
            </Style.Triggers>
        </Style>

        <Style TargetType="{x:Type TextBox}">
            <Setter Property="Padding" Value="10,7" />
            <Setter Property="MinHeight" Value="32" />
            <Setter Property="FontSize" Value="13" />
            <Setter Property="Foreground" Value="{StaticResource TextBodyBrush}" />
            <Setter Property="Background" Value="{StaticResource SurfaceBrush}" />
            <Setter Property="BorderBrush" Value="{StaticResource BorderStrongBrush}" />
            <Setter Property="BorderThickness" Value="1" />
            <Setter Property="FocusVisualStyle" Value="{x:Null}" />
            <Style.Triggers>
                <Trigger Property="IsKeyboardFocused" Value="True">
                    <Setter Property="BorderBrush" Value="{StaticResource PrimaryBrush}" />
                </Trigger>
                <Trigger Property="IsEnabled" Value="False">
                    <Setter Property="Background" Value="#F3F5F8" />
                    <Setter Property="Foreground" Value="#A4AFBC" />
                </Trigger>
            </Style.Triggers>
        </Style>
        <Style TargetType="{x:Type ComboBox}">
            <Setter Property="Padding" Value="10,5" />
            <Setter Property="MinHeight" Value="34" />
            <Setter Property="FontSize" Value="13" />
            <Setter Property="Foreground" Value="{StaticResource TextBodyBrush}" />
            <Setter Property="Background" Value="{StaticResource SurfaceBrush}" />
            <Setter Property="BorderBrush" Value="{StaticResource BorderStrongBrush}" />
            <Setter Property="BorderThickness" Value="1" />
            <Setter Property="FocusVisualStyle" Value="{x:Null}" />
            <Style.Triggers>
                <Trigger Property="IsKeyboardFocusWithin" Value="True">
                    <Setter Property="BorderBrush" Value="{StaticResource PrimaryBrush}" />
                </Trigger>
                <Trigger Property="IsEnabled" Value="False">
                    <Setter Property="Background" Value="#F3F5F8" />
                    <Setter Property="Foreground" Value="#A4AFBC" />
                </Trigger>
            </Style.Triggers>
        </Style>
        <Style TargetType="{x:Type ComboBoxItem}">
            <Setter Property="Padding" Value="10,7" />
            <Setter Property="Foreground" Value="{StaticResource TextBodyBrush}" />
            <Setter Property="Background" Value="{StaticResource SurfaceBrush}" />
            <Style.Triggers>
                <Trigger Property="IsMouseOver" Value="True">
                    <Setter Property="Background" Value="{StaticResource SurfaceHoverBrush}" />
                </Trigger>
                <Trigger Property="IsSelected" Value="True">
                    <Setter Property="Background" Value="{StaticResource PrimarySoftBrush}" />
                    <Setter Property="Foreground" Value="{StaticResource PrimaryBrush}" />
                </Trigger>
            </Style.Triggers>
        </Style>
        <Style TargetType="{x:Type ProgressBar}">
            <Setter Property="Foreground" Value="{StaticResource PrimaryBrush}" />
            <Setter Property="Background" Value="#E7EDF4" />
        </Style>
        <Style x:Key="RecoveryLevelItemStyle" TargetType="{x:Type ListBoxItem}">
            <Setter Property="Background" Value="{StaticResource SurfaceBrush}" />
            <Setter Property="Foreground" Value="{StaticResource TextStrongBrush}" />
            <Setter Property="BorderBrush" Value="{StaticResource BorderBrush}" />
            <Setter Property="BorderThickness" Value="1" />
            <Setter Property="Padding" Value="12" />
            <Setter Property="MinHeight" Value="82" />
            <Setter Property="HorizontalContentAlignment" Value="Stretch" />
            <Setter Property="VerticalContentAlignment" Value="Center" />
            <Setter Property="FocusVisualStyle" Value="{x:Null}" />
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="{x:Type ListBoxItem}">
                        <Border Background="{TemplateBinding Background}"
                                BorderBrush="{TemplateBinding BorderBrush}"
                                BorderThickness="{TemplateBinding BorderThickness}"
                                CornerRadius="8"
                                Padding="{TemplateBinding Padding}">
                            <ContentPresenter HorizontalAlignment="{TemplateBinding HorizontalContentAlignment}"
                                              VerticalAlignment="{TemplateBinding VerticalContentAlignment}" />
                        </Border>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
            <Style.Triggers>
                <Trigger Property="IsSelected" Value="True">
                    <Setter Property="Background" Value="{StaticResource PrimarySoftBrush}" />
                    <Setter Property="Foreground" Value="{StaticResource PrimaryBrush}" />
                    <Setter Property="BorderBrush" Value="{StaticResource PrimaryBrush}" />
                    <Setter Property="BorderThickness" Value="2" />
                </Trigger>
                <MultiTrigger>
                    <MultiTrigger.Conditions>
                        <Condition Property="IsMouseOver" Value="True" />
                        <Condition Property="IsSelected" Value="False" />
                    </MultiTrigger.Conditions>
                    <Setter Property="Background" Value="{StaticResource SurfaceHoverBrush}" />
                    <Setter Property="BorderBrush" Value="{StaticResource DropZoneBorderBrush}" />
                </MultiTrigger>
            </Style.Triggers>
        </Style>
    </Window.Resources>
    <ScrollViewer VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled">
        <Grid Margin="22">
            <Grid.RowDefinitions>
                <RowDefinition Height="Auto" />
                <RowDefinition Height="14" />
                <RowDefinition Height="Auto" />
                <RowDefinition Height="14" />
                <RowDefinition Height="Auto" />
                <RowDefinition Height="14" />
                <RowDefinition Height="Auto" />
                <RowDefinition Height="14" />
                <RowDefinition Height="Auto" />
                <RowDefinition Height="14" />
                <RowDefinition Height="Auto" />
                <RowDefinition Height="14" />
                <RowDefinition Height="Auto" />
            </Grid.RowDefinitions>

            <Border Grid.Row="0" Style="{StaticResource CardStyle}" Padding="18,16">
                <Grid>
                    <Grid.ColumnDefinitions>
                        <ColumnDefinition Width="Auto" />
                        <ColumnDefinition Width="16" />
                        <ColumnDefinition Width="*" />
                    </Grid.ColumnDefinitions>
                    <Image x:Name="AppIconImage" Grid.Column="0" Width="54" Height="54" Stretch="Uniform" />
                    <StackPanel Grid.Column="2" VerticalAlignment="Center">
                        <TextBlock Style="{StaticResource PageTitleStyle}" Text="压缩包密码恢复" />
                        <TextBlock Style="{StaticResource SubtitleStyle}" Margin="0,5,0,0" Text="完全本地运行 · 文件与密码不会上传" />
                    </StackPanel>
                </Grid>
            </Border>

            <Border x:Name="ArchiveDropZone" Grid.Row="2" AllowDrop="True" Background="{StaticResource SurfaceSubtleBrush}" BorderBrush="{StaticResource DropZoneBorderBrush}" BorderThickness="1" CornerRadius="10" Padding="16" MinHeight="176">
                <Grid>
                    <Rectangle Margin="1" RadiusX="9" RadiusY="9" Stroke="{StaticResource DropZoneBorderBrush}" StrokeThickness="1.2" StrokeDashArray="5,3" IsHitTestVisible="False" />
                    <StackPanel x:Name="EmptyArchiveDropContent" HorizontalAlignment="Center" VerticalAlignment="Center">
                        <Grid Width="54" Height="54" HorizontalAlignment="Center">
                            <Border Width="50" Height="50" CornerRadius="15" Background="{StaticResource PrimarySoftBrush}" HorizontalAlignment="Left" VerticalAlignment="Top">
                                <TextBlock HorizontalAlignment="Center" VerticalAlignment="Center" FontFamily="Segoe MDL2 Assets" FontSize="27" Foreground="{StaticResource PrimaryBrush}" Text="&#xE8B7;" />
                            </Border>
                            <Border Width="21" Height="21" CornerRadius="11" Background="{StaticResource PrimaryBrush}" BorderBrush="White" BorderThickness="2" HorizontalAlignment="Right" VerticalAlignment="Bottom">
                                <TextBlock HorizontalAlignment="Center" VerticalAlignment="Center" FontSize="17" Foreground="White" Text="+" />
                            </Border>
                        </Grid>
                        <TextBlock Margin="0,9,0,0" HorizontalAlignment="Center" FontSize="23" FontWeight="SemiBold" Foreground="{StaticResource TextStrongBrush}" Text="把压缩包拖到这里" />
                        <TextBlock Margin="0,5,0,0" HorizontalAlignment="Center" Style="{StaticResource SubtitleStyle}" Text="或点击选择 ZIP / 7z / RAR 文件" />
                        <Button x:Name="BrowseArchiveButton" Width="154" Height="38" Margin="0,14,0,0" HorizontalAlignment="Center" Style="{StaticResource PrimaryButtonStyle}" Content="选择文件" />
                    </StackPanel>
                    <Grid x:Name="SelectedArchiveCard" Visibility="Collapsed" VerticalAlignment="Center" Margin="12,0">
                        <Grid.ColumnDefinitions>
                            <ColumnDefinition Width="Auto" />
                            <ColumnDefinition Width="14" />
                            <ColumnDefinition Width="*" />
                            <ColumnDefinition Width="16" />
                            <ColumnDefinition Width="Auto" />
                        </Grid.ColumnDefinitions>
                        <Border Grid.Column="0" Width="46" Height="46" CornerRadius="12" Background="{StaticResource PrimarySoftBrush}">
                            <TextBlock HorizontalAlignment="Center" VerticalAlignment="Center" FontFamily="Segoe MDL2 Assets" FontSize="23" Foreground="{StaticResource PrimaryBrush}" Text="&#xE8B7;" />
                        </Border>
                        <StackPanel Grid.Column="2" VerticalAlignment="Center">
                            <TextBlock x:Name="ArchiveFileNameText" FontSize="17" FontWeight="SemiBold" Foreground="{StaticResource TextStrongBrush}" TextTrimming="CharacterEllipsis" />
                            <TextBlock x:Name="ArchiveInfoText" Margin="0,5,0,0" Style="{StaticResource SubtitleStyle}" TextTrimming="CharacterEllipsis" />
                        </StackPanel>
                        <Button x:Name="ReplaceArchiveButton" Grid.Column="4" Width="120" Height="36" VerticalAlignment="Center" Content="更换文件" />
                    </Grid>
                    <TextBox x:Name="ArchivePathBox" Visibility="Collapsed" />
                    <Button x:Name="InspectButton" Visibility="Collapsed" />
                </Grid>
            </Border>

            <Border Grid.Row="4" Style="{StaticResource CardStyle}">
                <StackPanel>
                    <Grid>
                        <Grid.ColumnDefinitions>
                            <ColumnDefinition Width="*" />
                            <ColumnDefinition Width="Auto" />
                        </Grid.ColumnDefinitions>
                        <TextBlock Style="{StaticResource SectionTitleStyle}" Text="恢复级别" />
                        <TextBlock Grid.Column="1" Style="{StaticResource HelperTextStyle}" VerticalAlignment="Center" Text="选择搜索深度" />
                    </Grid>
                    <ListBox x:Name="StrategyBox" Margin="0,14,0,0" Background="Transparent" BorderThickness="0" SelectedIndex="0" HorizontalContentAlignment="Stretch" ItemContainerStyle="{StaticResource RecoveryLevelItemStyle}">
                        <ListBox.ItemsPanel>
                            <ItemsPanelTemplate>
                                <UniformGrid Columns="5" />
                            </ItemsPanelTemplate>
                        </ListBox.ItemsPanel>
                        <ListBoxItem Tag="1" Padding="12" Margin="0,0,8,0">
                            <Grid>
                                <Grid.ColumnDefinitions>
                                    <ColumnDefinition Width="*" />
                                    <ColumnDefinition Width="30" />
                                </Grid.ColumnDefinitions>
                                <StackPanel Grid.Column="0" VerticalAlignment="Center">
                                    <TextBlock FontSize="19" FontWeight="SemiBold" Text="1级" />
                                    <TextBlock Margin="0,4,0,0" Style="{StaticResource SubtitleStyle}" Text="快速尝试" />
                                </StackPanel>
                                <TextBlock Grid.Column="1" HorizontalAlignment="Right" VerticalAlignment="Center" FontSize="25" Foreground="{StaticResource TextFaintBrush}" Text="↗" />
                            </Grid>
                        </ListBoxItem>
                        <ListBoxItem Tag="2" Padding="12" Margin="0,0,8,0">
                            <Grid>
                                <Grid.ColumnDefinitions>
                                    <ColumnDefinition Width="*" />
                                    <ColumnDefinition Width="30" />
                                </Grid.ColumnDefinitions>
                                <StackPanel Grid.Column="0" VerticalAlignment="Center">
                                    <TextBlock FontSize="19" FontWeight="SemiBold" Text="2级" />
                                    <TextBlock Margin="0,4,0,0" Style="{StaticResource SubtitleStyle}" Text="常用密码" />
                                </StackPanel>
                                <TextBlock Grid.Column="1" HorizontalAlignment="Right" VerticalAlignment="Center" FontSize="23" Foreground="{StaticResource TextFaintBrush}" Text="▣" />
                            </Grid>
                        </ListBoxItem>
                        <ListBoxItem Tag="3" Padding="12" Margin="0,0,8,0">
                            <Grid>
                                <Grid.ColumnDefinitions>
                                    <ColumnDefinition Width="*" />
                                    <ColumnDefinition Width="30" />
                                </Grid.ColumnDefinitions>
                                <StackPanel Grid.Column="0" VerticalAlignment="Center">
                                    <TextBlock FontSize="19" FontWeight="SemiBold" Text="3级" />
                                    <TextBlock Margin="0,4,0,0" Style="{StaticResource SubtitleStyle}" Text="增强恢复" />
                                </StackPanel>
                                <TextBlock Grid.Column="1" HorizontalAlignment="Right" VerticalAlignment="Center" FontSize="25" Foreground="{StaticResource TextFaintBrush}" Text="◇" />
                            </Grid>
                        </ListBoxItem>
                        <ListBoxItem Tag="4" Padding="12" Margin="0,0,8,0">
                            <Grid>
                                <Grid.ColumnDefinitions>
                                    <ColumnDefinition Width="*" />
                                    <ColumnDefinition Width="30" />
                                </Grid.ColumnDefinitions>
                                <StackPanel Grid.Column="0" VerticalAlignment="Center">
                                    <TextBlock FontSize="19" FontWeight="SemiBold" Text="4级" />
                                    <TextBlock Margin="0,4,0,0" Style="{StaticResource SubtitleStyle}" Text="深度搜索" />
                                </StackPanel>
                                <TextBlock Grid.Column="1" HorizontalAlignment="Right" VerticalAlignment="Center" FontSize="25" Foreground="{StaticResource TextFaintBrush}" Text="⌕" />
                            </Grid>
                        </ListBoxItem>
                        <ListBoxItem Tag="5" Padding="12">
                            <Grid>
                                <Grid.ColumnDefinitions>
                                    <ColumnDefinition Width="*" />
                                    <ColumnDefinition Width="30" />
                                </Grid.ColumnDefinitions>
                                <StackPanel Grid.Column="0" VerticalAlignment="Center">
                                    <TextBlock FontSize="19" FontWeight="SemiBold" Text="5级" />
                                    <TextBlock Margin="0,4,0,0" Style="{StaticResource SubtitleStyle}" Text="完整搜索" />
                                </StackPanel>
                                <TextBlock Grid.Column="1" HorizontalAlignment="Right" VerticalAlignment="Center" FontSize="23" Foreground="{StaticResource TextFaintBrush}" Text="◎" />
                            </Grid>
                        </ListBoxItem>
                    </ListBox>
                    <TextBlock x:Name="StrategyHelpText" Margin="0,12,0,0" TextWrapping="Wrap" Style="{StaticResource HelperTextStyle}" />
                </StackPanel>
            </Border>

            <Border x:Name="OverallProgressPanel" Grid.Row="6" Style="{StaticResource CardStyle}" Padding="18">
                <StackPanel>
                    <Grid>
                        <Grid.ColumnDefinitions>
                            <ColumnDefinition Width="*" />
                            <ColumnDefinition Width="Auto" />
                        </Grid.ColumnDefinitions>
                        <StackPanel Grid.Column="0">
                            <TextBlock x:Name="OverallProgressTitle" FontSize="21" FontWeight="SemiBold" Foreground="{StaticResource TextStrongBrush}" Text="整体恢复进度" />
                            <TextBlock x:Name="OverallProgressSubtitle" Margin="0,3,0,0" Style="{StaticResource HelperTextStyle}" Text="按已选择恢复级别统计整体搜索进展" />
                        </StackPanel>
                        <TextBlock x:Name="OverallProgressPercent" Grid.Column="1" HorizontalAlignment="Right" Margin="16,0,0,0" VerticalAlignment="Center" FontSize="19" FontWeight="SemiBold" Foreground="{StaticResource PrimaryBrush}" Text="—" />
                    </Grid>
                    <ProgressBar x:Name="OverallProgressBar" Height="10" Margin="0,13,0,0" Minimum="0" Maximum="100" Value="0" IsIndeterminate="False" Background="#E7EDF4" Foreground="{StaticResource PrimaryBrush}" />
                    <Grid x:Name="OverallProgressStatsGrid" Margin="0,18,0,0">
                        <Grid.ColumnDefinitions>
                            <ColumnDefinition Width="*" />
                            <ColumnDefinition Width="1" />
                            <ColumnDefinition Width="*" />
                            <ColumnDefinition Width="1" />
                            <ColumnDefinition Width="*" />
                            <ColumnDefinition Width="1" />
                            <ColumnDefinition Width="*" />
                        </Grid.ColumnDefinitions>
                        <StackPanel Grid.Column="0" Margin="0,0,14,0">
                            <TextBlock x:Name="OverallEtaLabel" Style="{StaticResource KpiLabelStyle}" ToolTip="表示按当前恢复级别耗尽已配置搜索范围所需的预计时间；密码可能更早找到，也可能不在当前搜索范围内。" Text="预计完成" />
                            <TextBlock x:Name="OverallEtaValue" Margin="0,4,0,0" TextWrapping="Wrap" Style="{StaticResource KpiValueStyle}" Text="开始搜索后显示" />
                        </StackPanel>
                        <Border Grid.Column="1" Background="{StaticResource DividerBrush}" />
                        <StackPanel Grid.Column="2" Margin="14,0,14,0">
                            <TextBlock x:Name="OverallCandidatesTestedLabel" Style="{StaticResource KpiLabelStyle}" Text="已累计测试" />
                            <TextBlock x:Name="OverallCandidatesTestedValue" Margin="0,4,0,0" TextWrapping="Wrap" Style="{StaticResource KpiValueStyle}" Text="等待开始" />
                        </StackPanel>
                        <Border Grid.Column="3" Background="{StaticResource DividerBrush}" />
                        <StackPanel Grid.Column="4" Margin="14,0,14,0">
                            <TextBlock x:Name="OverallCandidatesRemainingLabel" Style="{StaticResource KpiLabelStyle}" Text="剩余待尝试" />
                            <TextBlock x:Name="OverallCandidatesRemainingValue" Margin="0,4,0,0" TextWrapping="Wrap" Style="{StaticResource KpiValueStyle}" Text="准备后显示" />
                        </StackPanel>
                        <Border Grid.Column="5" Background="{StaticResource DividerBrush}" />
                        <StackPanel Grid.Column="6" Margin="14,0,0,0">
                            <TextBlock x:Name="OverallSpeedLabel" Style="{StaticResource KpiLabelStyle}" Text="当前搜索速度" />
                            <TextBlock x:Name="OverallSpeedValue" Margin="0,4,0,0" TextWrapping="Wrap" Style="{StaticResource KpiValueStyle}" Text="开始搜索后显示" />
                        </StackPanel>
                    </Grid>
                    <Border Margin="0,17,0,0" Padding="0,14,0,0" BorderBrush="{StaticResource DividerBrush}" BorderThickness="0,1,0,0">
                        <Grid x:Name="OverallProgressContextGrid">
                            <Grid.ColumnDefinitions>
                                <ColumnDefinition Width="*" />
                                <ColumnDefinition Width="*" />
                                <ColumnDefinition Width="*" />
                                <ColumnDefinition Width="*" />
                            </Grid.ColumnDefinitions>
                            <StackPanel Grid.Column="0" Margin="0,0,12,0">
                                <TextBlock Style="{StaticResource DetailLabelStyle}" Text="已处理范围" />
                                <TextBlock x:Name="OverallProgressSummary" Margin="0,3,0,0" TextWrapping="Wrap" Style="{StaticResource DetailValueStyle}" Text="准备后显示" />
                            </StackPanel>
                            <StackPanel Grid.Column="1" Margin="12,0,12,0">
                                <TextBlock Style="{StaticResource DetailLabelStyle}" Text="当前阶段" />
                                <TextBlock x:Name="OverallStageValue" Margin="0,3,0,0" TextWrapping="Wrap" Style="{StaticResource DetailValueStyle}" Text="等待开始" />
                            </StackPanel>
                            <StackPanel Grid.Column="2" Margin="12,0,12,0">
                                <TextBlock Style="{StaticResource DetailLabelStyle}" Text="当前范围" />
                                <TextBlock x:Name="OverallCoverageValue" Margin="0,3,0,0" TextWrapping="Wrap" Style="{StaticResource DetailValueStyle}" Text="等待开始" />
                            </StackPanel>
                            <StackPanel Grid.Column="3" Margin="12,0,0,0">
                                <TextBlock Style="{StaticResource DetailLabelStyle}" Text="当前状态" />
                                <TextBlock x:Name="OverallProgressCurrent" Margin="0,3,0,0" TextWrapping="Wrap" Style="{StaticResource DetailValueStyle}" Text="等待开始" />
                            </StackPanel>
                        </Grid>
                    </Border>
                    <TextBlock x:Name="OverallProgressHelper" Margin="0,11,0,0" TextWrapping="Wrap" Style="{StaticResource HelperTextStyle}" Text="" Visibility="Collapsed" />
                </StackPanel>
            </Border>

            <Border Grid.Row="8" Style="{StaticResource CardStyle}" Padding="18,15">
                <Grid>
                    <Grid.ColumnDefinitions>
                        <ColumnDefinition Width="*" />
                        <ColumnDefinition Width="18" />
                        <ColumnDefinition Width="Auto" />
                    </Grid.ColumnDefinitions>
                    <StackPanel Grid.Column="0">
                        <TextBlock Style="{StaticResource SectionTitleStyle}" Text="计算设备" />
                        <ComboBox x:Name="DeviceBox" Width="320" Margin="0,10,0,0" MinHeight="34" HorizontalAlignment="Left" />
                        <TextBlock x:Name="DeviceInfoText" Margin="0,8,0,0" TextWrapping="Wrap" Style="{StaticResource HelperTextStyle}" Text="可用：CPU" />
                    </StackPanel>
                <StackPanel Grid.Column="2" VerticalAlignment="Center">
                    <Button x:Name="StartButton" Width="200" Height="52" Style="{StaticResource PrimaryButtonStyle}" Content="开始恢复" />
                    <StackPanel Orientation="Horizontal" HorizontalAlignment="Center" Margin="0,9,0,0">
                        <Button x:Name="PauseButton" Width="68" Margin="0,0,6,0" Content="暂停" Visibility="Collapsed" />
                        <Button x:Name="ResumeButton" Width="68" Margin="0,0,6,0" Content="继续" Visibility="Collapsed" />
                        <Button x:Name="StopButton" Width="68" Content="停止" Visibility="Collapsed" />
                    </StackPanel>
                </StackPanel>
                </Grid>
            </Border>

            <Border x:Name="ProgressCard" Grid.Row="10" Style="{StaticResource CardStyle}" Padding="18">
                <Grid>
                    <Grid.ColumnDefinitions>
                        <ColumnDefinition Width="128" />
                        <ColumnDefinition Width="*" />
                        <ColumnDefinition Width="128" />
                        <ColumnDefinition Width="*" />
                    </Grid.ColumnDefinitions>
                    <Grid.RowDefinitions>
                        <RowDefinition Height="Auto" />
                        <RowDefinition Height="12" />
                        <RowDefinition Height="Auto" />
                        <RowDefinition Height="12" />
                        <RowDefinition Height="Auto" />
                        <RowDefinition Height="12" />
                        <RowDefinition Height="Auto" />
                        <RowDefinition Height="12" />
                        <RowDefinition Height="Auto" />
                        <RowDefinition Height="12" />
                        <RowDefinition Height="Auto" />
                        <RowDefinition Height="12" />
                        <RowDefinition Height="Auto" />
                        <RowDefinition Height="12" />
                        <RowDefinition Height="Auto" />
                        <RowDefinition Height="12" />
                        <RowDefinition Height="Auto" />
                    </Grid.RowDefinitions>
                    <TextBlock Grid.Row="0" Grid.Column="0" Style="{StaticResource SectionTitleStyle}" Text="当前范围详情" />
                    <Border Grid.Row="0" Grid.Column="1" HorizontalAlignment="Left" Style="{StaticResource BadgeStyle}">
                        <TextBlock x:Name="StateValue" FontSize="13" FontWeight="SemiBold" Foreground="{StaticResource PrimaryBrush}" />
                    </Border>
                    <TextBlock Grid.Row="0" Grid.Column="2" Style="{StaticResource DetailLabelStyle}" VerticalAlignment="Center" Text="当前阶段" />
                    <TextBlock x:Name="StageValue" Grid.Row="0" Grid.Column="3" TextWrapping="Wrap" FontSize="16" FontWeight="SemiBold" Foreground="{StaticResource PrimaryBrush}" />
                    <TextBlock Grid.Row="2" Grid.Column="0" Style="{StaticResource DetailLabelStyle}" Text="当前范围" />
                    <TextBlock x:Name="CoverageValue" Grid.Row="2" Grid.Column="1" TextWrapping="Wrap" Style="{StaticResource DetailValueStyle}" />
                    <TextBlock Grid.Row="2" Grid.Column="2" Style="{StaticResource DetailLabelStyle}" Text="当前设备" />
                    <TextBlock x:Name="DeviceValue" Grid.Row="2" Grid.Column="3" TextWrapping="Wrap" Style="{StaticResource DetailValueStyle}" />
                    <TextBlock Grid.Row="4" Grid.Column="0" Style="{StaticResource DetailLabelStyle}" Text="当前 Backend" />
                    <TextBlock x:Name="EngineValue" Grid.Row="4" Grid.Column="1" TextWrapping="Wrap" Style="{StaticResource DetailValueStyle}" />
                    <TextBlock x:Name="SpeedLabel" Grid.Row="4" Grid.Column="2" Style="{StaticResource DetailLabelStyle}" Text="速度（平滑）" />
                    <TextBlock x:Name="SpeedValue" Grid.Row="4" Grid.Column="3" FontSize="15" FontWeight="SemiBold" Foreground="{StaticResource TextBodyBrush}" />
                    <TextBlock x:Name="ProgressMetricLabel" Grid.Row="6" Grid.Column="0" Style="{StaticResource DetailLabelStyle}" Text="已测试数量" />
                    <TextBlock x:Name="CandidatesValue" Grid.Row="6" Grid.Column="1" Style="{StaticResource DetailValueStyle}" />
                    <TextBlock Grid.Row="6" Grid.Column="2" Style="{StaticResource DetailLabelStyle}" Text="当前范围预计剩余" />
                    <TextBlock x:Name="EstimatedRemainingValue" Grid.Row="6" Grid.Column="3" FontSize="15" FontWeight="SemiBold" Foreground="{StaticResource TextStrongBrush}" />
                    <TextBlock Grid.Row="8" Grid.Column="0" Style="{StaticResource DetailLabelStyle}" Text="当前范围最坏时间" />
                    <TextBlock x:Name="WorstCaseValue" Grid.Row="8" Grid.Column="1" Grid.ColumnSpan="3" TextWrapping="Wrap" FontSize="15" FontWeight="SemiBold" Foreground="{StaticResource TextStrongBrush}" />
                    <TextBlock x:Name="ProgressBarLabel" Grid.Row="10" Grid.Column="0" Style="{StaticResource DetailLabelStyle}" VerticalAlignment="Center" Text="搜索进度" />
                    <ProgressBar x:Name="SearchProgressBar" Grid.Row="10" Grid.Column="1" Height="10" Minimum="0" Maximum="100" />
                    <TextBlock x:Name="ProgressPercentValue" Grid.Row="10" Grid.Column="2" Grid.ColumnSpan="2" Margin="10,0,0,0" VerticalAlignment="Center" Foreground="{StaticResource PrimaryBrush}" FontWeight="SemiBold" />
                    <Border x:Name="ResultCard" Grid.Row="12" Grid.Column="0" Grid.ColumnSpan="4" Background="{StaticResource SuccessSurfaceBrush}" BorderBrush="{StaticResource SuccessBorderBrush}" BorderThickness="1" CornerRadius="7" Padding="12" Visibility="Collapsed">
                        <Grid>
                            <Grid.ColumnDefinitions>
                                <ColumnDefinition Width="Auto" />
                                <ColumnDefinition Width="16" />
                                <ColumnDefinition Width="*" />
                            </Grid.ColumnDefinitions>
                            <TextBlock x:Name="ResultStatusText" Grid.Column="0" VerticalAlignment="Center" FontWeight="SemiBold" Foreground="{StaticResource SuccessTextBrush}" Text="密码已恢复" />
                            <TextBox x:Name="ResultValue" Grid.Column="2" IsReadOnly="True" FontSize="16" FontWeight="SemiBold" Background="White" />
                        </Grid>
                    </Border>
                    <Grid Grid.Row="16" Grid.Column="0" Grid.ColumnSpan="4">
                        <Grid.ColumnDefinitions>
                            <ColumnDefinition Width="*" />
                            <ColumnDefinition Width="120" />
                            <ColumnDefinition Width="Auto" />
                        </Grid.ColumnDefinitions>
                        <TextBlock x:Name="ProgressMessageText" Grid.Column="0" TextWrapping="Wrap" Style="{StaticResource HelperTextStyle}" />
                        <TextBlock Grid.Column="1" HorizontalAlignment="Right" Style="{StaticResource HelperTextStyle}" Text="已运行" />
                        <TextBlock x:Name="ElapsedValue" Grid.Column="2" Margin="10,0,0,0" Foreground="{StaticResource TextBodyBrush}" FontWeight="SemiBold" />
                    </Grid>
                </Grid>
            </Border>

            <Border Grid.Row="12" Style="{StaticResource CardStyle}" Padding="0">
                <Expander x:Name="AdvancedSettingsExpander" IsExpanded="False" Padding="16,14" Background="Transparent" BorderThickness="0">
                    <Expander.Header>
                        <Grid>
                            <Grid.ColumnDefinitions>
                                <ColumnDefinition Width="Auto" />
                                <ColumnDefinition Width="9" />
                                <ColumnDefinition Width="Auto" />
                            </Grid.ColumnDefinitions>
                            <TextBlock Grid.Column="0" FontFamily="Segoe MDL2 Assets" FontSize="15" Foreground="{StaticResource TextMutedBrush}" Text="&#xE713;" />
                            <TextBlock Grid.Column="2" FontSize="14" FontWeight="SemiBold" Foreground="{StaticResource TextBodyBrush}" Text="高级设置（可选）" />
                        </Grid>
                    </Expander.Header>
                    <StackPanel>
                    <TextBlock Margin="0,0,0,14" TextWrapping="Wrap" Style="{StaticResource HelperTextStyle}" Text="普通用户无需展开。这里保留 Quick 候选、字典、Mask / Hybrid、字符集、长度范围和技术信息。" />
                    <Grid>
                        <Grid.ColumnDefinitions>
                            <ColumnDefinition Width="125" />
                            <ColumnDefinition Width="*" />
                            <ColumnDefinition Width="105" />
                            <ColumnDefinition Width="75" />
                            <ColumnDefinition Width="75" />
                            <ColumnDefinition Width="75" />
                        </Grid.ColumnDefinitions>
                        <Grid.RowDefinitions>
                            <RowDefinition Height="Auto" />
                            <RowDefinition Height="8" />
                            <RowDefinition Height="Auto" />
                            <RowDefinition Height="8" />
                            <RowDefinition Height="Auto" />
                            <RowDefinition Height="8" />
                            <RowDefinition Height="Auto" />
                        </Grid.RowDefinitions>
                        <TextBlock Grid.Row="0" Grid.Column="0" VerticalAlignment="Top" Style="{StaticResource DetailLabelStyle}" Text="Quick 候选" />
                        <TextBox x:Name="QuickCandidatesBox" Grid.Row="0" Grid.Column="1" Grid.ColumnSpan="5" Height="72" AcceptsReturn="True" VerticalScrollBarVisibility="Auto" TextWrapping="Wrap" ToolTip="每行输入一个准确候选密码" />
                        <TextBlock Grid.Row="2" Grid.Column="0" VerticalAlignment="Center" Style="{StaticResource DetailLabelStyle}" Text="本地字典" />
                        <TextBox x:Name="DictionaryPathBox" Grid.Row="2" Grid.Column="1" MinHeight="32" VerticalContentAlignment="Center" />
                        <Button x:Name="BrowseDictionaryButton" Grid.Row="2" Grid.Column="2" Grid.ColumnSpan="2" MinHeight="32" Content="选择文件" />
                        <CheckBox x:Name="TryEmptyPasswordBox" Grid.Row="2" Grid.Column="4" Grid.ColumnSpan="2" VerticalAlignment="Center" Content="先尝试空密码" />
                        <TextBlock Grid.Row="4" Grid.Column="0" VerticalAlignment="Center" Style="{StaticResource DetailLabelStyle}" Text="Mask / Hybrid" />
                        <TextBox x:Name="MaskBox" Grid.Row="4" Grid.Column="1" MinHeight="32" VerticalContentAlignment="Center" ToolTip="示例：Summer?d?d、?w?d?d、?u?l?l?d?d" />
                        <TextBlock Grid.Row="4" Grid.Column="2" Grid.ColumnSpan="4" Margin="10,0,0,0" VerticalAlignment="Center" TextWrapping="Wrap" Style="{StaticResource HelperTextStyle}" Text="?l 小写，?u 大写，?d 数字，?s 符号，?a 全部字符，?w 一个字典词，?? 为字面量问号。" />
                        <TextBlock Grid.Row="6" Grid.Column="0" VerticalAlignment="Center" Style="{StaticResource DetailLabelStyle}" Text="穷举范围" />
                        <ComboBox x:Name="CharacterSetBox" Grid.Row="6" Grid.Column="1" MinHeight="32" />
                        <TextBox x:Name="CustomCharacterSetBox" Grid.Row="6" Grid.Column="2" MinHeight="32" Margin="10,0,0,0" ToolTip="仅在选择自定义字符集时使用" />
                        <TextBlock Grid.Row="6" Grid.Column="3" VerticalAlignment="Center" Margin="10,0,0,0" Style="{StaticResource DetailLabelStyle}" Text="最小" />
                        <TextBox x:Name="MinLengthBox" Grid.Row="6" Grid.Column="4" MinHeight="32" Text="1" VerticalContentAlignment="Center" />
                        <TextBox x:Name="MaxLengthBox" Grid.Row="6" Grid.Column="5" MinHeight="32" Text="4" VerticalContentAlignment="Center" ToolTip="最大长度" />
                    </Grid>
                    <TextBlock x:Name="AdvancedDeviceInfoText" Margin="0,14,0,0" TextWrapping="Wrap" Style="{StaticResource HelperTextStyle}" />
                    <Button x:Name="OpenJobButton" Width="150" Margin="0,12,0,0" HorizontalAlignment="Left" Content="打开已保存任务" />
                    <TextBlock Margin="0,12,0,0" TextWrapping="Wrap" Style="{StaticResource HelperTextStyle}" Text="清除此压缩包由本工具保存的任务进度、断点、临时运行数据和测试状态，不会删除原压缩包或用户字典。" />
                    <StackPanel Orientation="Horizontal" Margin="0,8,0,0">
                        <Button x:Name="ResetCurrentArchiveButton" Width="190" MinHeight="32" HorizontalAlignment="Left" Content="恢复初始化（当前压缩包）" />
                        <Button x:Name="ClearPerformanceProfilesButton" Width="150" Margin="10,0,0,0" MinHeight="32" HorizontalAlignment="Left" Content="清理性能估算缓存" />
                    </StackPanel>
                    <TextBox x:Name="LogBox" Height="130" Margin="0,14,0,0" IsReadOnly="True" TextWrapping="Wrap" VerticalScrollBarVisibility="Auto" Background="#20242B" Foreground="#E6EDF3" BorderThickness="0" Padding="10" />
                    </StackPanel>
                </Expander>
            </Border>
        </Grid>
    </ScrollViewer>
</Window>
'@

$reader = New-Object System.Xml.XmlNodeReader $xaml
$window = [Windows.Markup.XamlReader]::Load($reader)

$controls = @{}
foreach ($name in @(
        'AppIconImage', 'ArchiveDropZone', 'EmptyArchiveDropContent', 'SelectedArchiveCard', 'ArchivePathBox', 'BrowseArchiveButton', 'ReplaceArchiveButton', 'InspectButton', 'ArchiveFileNameText', 'ArchiveInfoText',
        'StrategyBox', 'DeviceBox', 'StrategyHelpText', 'OverallProgressPanel', 'OverallProgressTitle', 'OverallProgressSubtitle', 'OverallProgressBar', 'OverallProgressPercent', 'OverallProgressStatsGrid', 'OverallEtaLabel', 'OverallCandidatesTestedLabel', 'OverallCandidatesRemainingLabel', 'OverallSpeedLabel', 'OverallCandidatesTestedValue', 'OverallCandidatesRemainingValue', 'OverallSpeedValue', 'OverallEtaValue', 'OverallProgressSummary', 'OverallProgressContextGrid', 'OverallStageValue', 'OverallCoverageValue', 'OverallProgressCurrent', 'OverallProgressHelper', 'DeviceInfoText',
        'QuickCandidatesBox', 'DictionaryPathBox', 'BrowseDictionaryButton', 'TryEmptyPasswordBox',
        'MaskBox', 'CharacterSetBox', 'CustomCharacterSetBox', 'MinLengthBox', 'MaxLengthBox',
        'StartButton', 'PauseButton', 'ResumeButton', 'StopButton', 'OpenJobButton', 'AdvancedSettingsExpander',
'StateValue', 'StageValue', 'CoverageValue', 'EngineValue', 'DeviceValue', 'ProgressMetricLabel', 'CandidatesValue', 'SpeedLabel', 'SpeedValue', 'ElapsedValue',
'EstimatedRemainingValue', 'WorstCaseValue', 'SearchProgressBar', 'ProgressPercentValue', 'ResultCard', 'ResultStatusText', 'ResultValue',
'ProgressBarLabel',
'ProgressMessageText', 'AdvancedDeviceInfoText', 'ResetCurrentArchiveButton', 'ClearPerformanceProfilesButton', 'LogBox'
    )) {
    $controls[$name] = $window.FindName($name)
}

$primaryIconPath = Join-Path $projectRoot 'assets\ArchivePasswordRecovery_Primary.ico'
if (Test-Path -LiteralPath $primaryIconPath -PathType Leaf) {
    $iconDecoder = New-Object System.Windows.Media.Imaging.IconBitmapDecoder(
        [System.Uri]::new($primaryIconPath, [System.UriKind]::Absolute),
        [System.Windows.Media.Imaging.BitmapCreateOptions]::PreservePixelFormat,
        [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad
    )
    $iconBitmap = @($iconDecoder.Frames | Sort-Object PixelWidth, PixelHeight -Descending | Select-Object -First 1)[0]
    $iconBitmap.Freeze()
    $controls.AppIconImage.Source = $iconBitmap
    $window.Icon = $iconBitmap
}

$script:CurrentJobDirectory = $null
$script:CurrentJobId = ''
$script:CurrentWorker = $null
$script:CurrentInspection = $null
$script:LastProgressUpdated = $null
$script:LastProgressSnapshot = $null
$script:DeviceSelectionWarning = ''
$script:UiElapsedRunId = ''
$script:UiElapsedRunStartedUtc = $null
$script:UiElapsedFrozenSeconds = $null
$script:UiElapsedLastSeconds = 0.0
$script:DeviceProbeState = 'Pending'
$script:DeviceProbeResult = $null
$script:DeviceProbeError = ''
$script:DeviceChoicesPopulated = $false
$script:DeferredStartupScheduled = $false
$script:DeferredStartupStarted = $false

function Write-UiLog {
    param([Parameter(Mandatory = $true)][string]$Message)

    $stamp = Get-Date -Format 'HH:mm:ss'
    $controls.LogBox.AppendText("[$stamp] $Message" + [Environment]::NewLine)
    $controls.LogBox.ScrollToEnd()
}

function Show-UiError {
    param([Parameter(Mandatory = $true)][string]$Message)

    $localized = Convert-UiMessage -Message $Message
    Write-UiLog $localized
    [System.Windows.MessageBox]::Show($window, $localized, '压缩包密码恢复', [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Error) | Out-Null
}

function Set-ArchiveDisplayState {
    param([Parameter(Mandatory = $true)][bool]$HasValidArchive)

    $visible = [System.Windows.Visibility]::Visible
    $collapsed = [System.Windows.Visibility]::Collapsed
    $controls.EmptyArchiveDropContent.Visibility = if ($HasValidArchive) { $collapsed } else { $visible }
    $controls.SelectedArchiveCard.Visibility = if ($HasValidArchive) { $visible } else { $collapsed }
    $controls.ArchiveDropZone.MinHeight = if ($HasValidArchive) { 0 } else { 170 }
    $padding = if ($HasValidArchive) { 16 } else { 24 }
    $controls.ArchiveDropZone.Padding = New-Object -TypeName System.Windows.Thickness -ArgumentList $padding
}

function Clear-SelectedArchive {
    $controls.ArchivePathBox.Text = ''
    $controls.ArchiveFileNameText.Text = ''
    $controls.ArchiveInfoText.Text = ''
    $script:CurrentInspection = $null
    Reset-UiElapsedState
    Set-ArchiveDisplayState -HasValidArchive:$false
    Update-TaskControls
}

function Add-LocalizedComboChoice {
    param(
        [Parameter(Mandatory = $true)]$Control,
        [Parameter(Mandatory = $true)][string]$DisplayText,
        [Parameter(Mandatory = $true)][string]$Value,
        $Metadata = $null
    )

    $item = New-Object System.Windows.Controls.ComboBoxItem
    $item.Content = $DisplayText
    $item.Tag = $Value
    if ($null -ne $Metadata) { $item.DataContext = $Metadata }
    [void]$Control.Items.Add($item)
    return $item
}

function Get-SelectedValue {
    param([Parameter(Mandatory = $true)]$Control)
    if ($null -eq $Control.SelectedItem) { return '' }
    if (($Control.SelectedItem -is [System.Windows.Controls.ComboBoxItem] -or
            $Control.SelectedItem -is [System.Windows.Controls.ListBoxItem]) -and
        -not [string]::IsNullOrWhiteSpace([string]$Control.SelectedItem.Tag)) {
        return [string]$Control.SelectedItem.Tag
    }
    return [string]$Control.SelectedItem
}

function Set-SelectedValue {
    param(
        [Parameter(Mandatory = $true)]$Control,
        [Parameter(Mandatory = $true)][string]$Value
    )

    foreach ($item in @($Control.Items)) {
        if (($item -is [System.Windows.Controls.ComboBoxItem] -or
                $item -is [System.Windows.Controls.ListBoxItem]) -and [string]$item.Tag -eq $Value) {
            $Control.SelectedItem = $item
            return $true
        }
        if ([string]$item -eq $Value) {
            $Control.SelectedItem = $item
            return $true
        }
    }
    return $false
}

function Get-UiObjectPropertyValue {
    param(
        $Object,
        [Parameter(Mandatory = $true)][string]$Name,
        $Default = $null
    )

    if ($null -eq $Object) { return $Default }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -ne $property) { return $property.Value }
    return $Default
}

function Get-SelectedDeviceJobSelection {
    $selectedItem = $controls.DeviceBox.SelectedItem
    $metadata = if ($selectedItem -is [System.Windows.Controls.ComboBoxItem]) { $selectedItem.DataContext } else { $null }
    $metadataVendor = [string](Get-UiObjectPropertyValue -Object $metadata -Name 'Vendor' -Default '')
    $metadataName = [string](Get-UiObjectPropertyValue -Object $metadata -Name 'Name' -Default '')
    if (-not [string]::IsNullOrWhiteSpace($metadataVendor) -and -not [string]::IsNullOrWhiteSpace($metadataName)) {
        [int]$lastDeviceId = -1
        try { $lastDeviceId = [int](Get-UiObjectPropertyValue -Object $metadata -Name 'LastDeviceId' -Default -1) } catch { $lastDeviceId = -1 }
        return [pscustomobject]@{
            Preference = 'GPU'
            SelectedGpu = [ordered]@{
                Backend = 'HashcatOpenCL'
                Vendor = $metadataVendor
                Name = $metadataName
                LastDeviceId = $lastDeviceId
            }
        }
    }

    return [pscustomobject]@{
        Preference = Get-SelectedValue -Control $controls.DeviceBox
        SelectedGpu = $null
    }
}

function Convert-StrategyName {
    param([string]$Value)

    switch ($Value) {
        'Quick' { return '快速尝试' }
        'Dictionary' { return '常用密码' }
        'Rules' { return '增强恢复' }
        'Mask' { return '深度搜索' }
        'BruteForce' { return '完整搜索' }
        default { return $Value }
    }
}

function Convert-StateName {
    param([string]$Value)

    switch ($Value) {
        'Idle' { return '空闲' }
        'Starting' { return '正在启动' }
        'Running' { return '运行中' }
        'Pausing' { return '正在暂停' }
        'Paused' { return '已暂停' }
        'Stopping' { return '正在停止' }
        'Stopped' { return '已停止' }
        'Interrupted' { return '任务已中断，可继续' }
        'Finalizing' { return '正在收尾' }
        'Recovered' { return '已恢复' }
        'Exhausted' { return '已完成（未找到密码）' }
        'Failed' { return '失败' }
        'BackendUnavailable' { return '后端不可用' }
        'NotEncrypted' { return '未加密' }
        default { return $Value }
    }
}

function Convert-BackendName {
    param([string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) { return '尚未启动' }
    switch ($Value) {
        'NanaZip local verifier' { return 'NanaZip 本地验证器' }
        'Hashcat OpenCL' { return 'Hashcat OpenCL' }
        default { return $Value }
    }
}

function Convert-ComputeDeviceName {
    param([string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) { return '尚未启动' }
    if ($Value -match '^AMD GPU \((.+)\)$') { return ('AMD 显卡（{0}）' -f $Matches[1]) }
    if ($Value -match '^NVIDIA GPU \((.+)\)$') { return ('NVIDIA 显卡（{0}）' -f $Matches[1]) }
    if ($Value -eq 'AMD GPU') { return 'AMD 显卡' }
    if ($Value -eq 'NVIDIA GPU') { return 'NVIDIA 显卡' }
    return $Value
}

function Convert-UiMessage {
    param([AllowNull()][string]$Message)

    if ([string]::IsNullOrWhiteSpace($Message)) { return '' }

    $exact = @{
        'Testing local candidates.' = '正在测试本地候选密码。'
        'Preparing the local recovery backend.' = '正在准备本地恢复后端。'
        'Preparing the local backend for coverage: ' = '正在准备当前覆盖范围的本地后端：'
        'Preparing the local backend for stage ' = '正在准备当前阶段的本地后端：'
        'Preparing local coverage: ' = '正在准备本地覆盖范围：'
        'Preparing local coverage for stage ' = '正在准备当前阶段的本地覆盖范围：'
        'Preparing local dictionary data for coverage: ' = '正在准备当前覆盖范围的本地字典数据：'
        'PLAN_DICTIONARY_SOURCE_INVALID: 计划项的字典来源定义不完整。' = '计划项的字典来源定义不完整。'
        'Preparing local attack data for stage ' = '正在准备当前阶段的本地攻击数据：'
        'Starting the local Hashcat backend.' = '正在启动本地 Hashcat 后端。'
        'Restoring the saved local Hashcat checkpoint.' = '正在恢复已保存的本地 Hashcat 断点。'
        'Verifying the current candidate locally.' = '正在本机验证当前候选密码。'
        'Advancing to the next local coverage.' = '正在切换到下一个本地覆盖范围。'
        'Coverage completed; advancing to the next local coverage.' = '当前覆盖范围已完成，正在切换到下一个本地覆盖范围。'
        'Synchronizing current search progress.' = '正在同步当前搜索进度…'
        'The archive does not require a password.' = '压缩包不需要密码。'
        'All selected local coverage completed without recovering a password.' = '所有选定的本地覆盖范围均已完成，未恢复出密码。'
        'The local recovery runtime artifact could not be created. The task was not marked as recovered.' = '无法创建本地恢复运行文件；任务不会标记为已恢复。'
        'Password recovered and verified locally.' = '密码已恢复，并已在本机验证。'
        'CPU was selected.' = '已选择 CPU。'
        'Starting the local John Jumbo bulk CPU search.' = '正在启动本地 John Jumbo 批量 CPU 搜索。'
        'John Jumbo is running a local bulk candidate search.' = 'John Jumbo 正在执行本地批量候选搜索。'
        'John Jumbo reported a password and NanaZip verified it locally.' = 'John Jumbo 报告了密码，且 NanaZip 已在本机验证成功。'
        'John Jumbo completed the local bulk candidate search without a verified password.' = 'John Jumbo 已完成本地批量候选搜索，未找到通过验证的密码。'
        'John Jumbo had no remaining candidates in the current local coverage.' = '当前本地覆盖范围没有剩余候选，John Jumbo 未启动搜索。'
        'Starting local Hashcat GPU recovery.' = '正在启动本地 Hashcat GPU 恢复。'
        'No saved Hashcat restore file was found; restarting the current GPU stage locally.' = '未找到已保存的 Hashcat 恢复文件；将从当前 GPU 阶段重新开始。'
        'Pausing locally by saving the Hashcat session checkpoint.' = '正在保存本地 Hashcat 会话断点并暂停。'
        'Stopping local Hashcat. Hashcat session data remains in this local job folder when available.' = '正在停止本地 Hashcat；可用的会话数据会保留在此本地任务目录。'
        'Hashcat reported a password and NanaZip verified it locally.' = 'Hashcat 报告了密码，且 NanaZip 已在本机验证成功。'
        'Hashcat reported a candidate, but NanaZip did not verify it. The task was not marked as recovered.' = 'Hashcat 报告了候选密码，但 NanaZip 未能验证；任务不会标记为已恢复。'
        'The selected local Hashcat GPU search completed without a verified password.' = '选定的本地 Hashcat GPU 搜索已完成，未找到通过验证的密码。'
        'The selected local strategy completed without recovering a password.' = '选定的本地恢复策略已完成，未恢复出密码。'
        'All selected recovery stages completed without recovering a password. Skipped stages were recorded in the local progress file.' = '所有选定恢复阶段均已完成，未恢复出密码；无法执行的阶段及原因已记录在本地进度文件中。'
        'The archive metadata indicates that no password is required; recovery was not started.' = '压缩包元数据表明不需要密码；未启动恢复。'
        'No usable local Hashcat GPU device was initialized. CPU fallback was selected.' = '未初始化可用的本地 Hashcat GPU；已回退到 CPU。'
        'Local Hashcat OpenCL devices were initialized successfully.' = '本地 Hashcat OpenCL 设备已成功初始化。'
        'Local Hashcat OpenCL devices are ready; implemented GPU routes include ZIP WinZip AES and 7-Zip AES when their local extractors are available.' = '本地 Hashcat OpenCL 设备已就绪；在对应本地提取器可用时，可使用 ZIP WinZip AES 与 7z AES 的 GPU 恢复路径。'
        'Overall total will continue to be estimated while the task runs.' = '整体总量将在执行过程中持续估算。'
        'The overall recovery plan is ready; preparing the local recovery backend.' = '整体恢复计划已就绪，正在准备本地恢复后端。'
        'Preparing the next coverage.' = '正在准备下一搜索范围。'
        'Preparing the local search.' = '正在准备本地搜索。'
        'Preparing the current coverage; overall ETA will update when preparation completes.' = '正在准备当前范围，整体预计时间将在搜索范围速度稳定后自动校正。'
        'Preparing the local search; overall ETA will update when search starts.' = '正在准备本地搜索，整体预计时间将在速度采样后自动校正。'
        'Starting the local search backend; overall ETA will update when search starts.' = '正在启动本地搜索后端，整体预计时间将在速度采样后自动校正。'
        'Restoring the saved local search checkpoint; overall ETA will update when search starts.' = '正在恢复已保存的本地搜索断点，整体预计时间将在速度采样后自动校正。'
        'Searching the current coverage.' = '正在搜索当前范围。'
        'Overall progress is pausing; the current checkpoint will remain available.' = '整体进度正在暂停，当前断点仍可继续使用。'
        'Overall progress is paused; resume to continue searching.' = '整体进度已暂停，点击“继续”恢复搜索。'
        'Overall progress is stopping; the current checkpoint will remain available.' = '整体进度正在停止，当前断点仍会保留。'
        'Overall progress stopped; resume to continue searching.' = '整体进度已停止，点击“继续”恢复搜索。'
        'Password recovered; subsequent search stopped.' = '密码已恢复，后续搜索已停止。'
        'All selected coverage completed without a verified password.' = '所有选定搜索范围均已完成，未找到通过验证的密码。'
        'The task failed; overall ETA is unavailable.' = '任务失败，整体预计时间暂不可用。'
        'Overall progress is being prepared.' = '正在准备整体进度信息。'
        'Quick candidates stay on the CPU because process startup would cost more than the search itself.' = '快速尝试的候选数量很少，进程启动开销高于搜索本身，因此使用 CPU。'
        'Dictionary candidates can use the local Hashcat wordlist attack.' = '字典候选可使用本地 Hashcat 字典攻击。'
        'Dictionary candidates can use the local Hashcat GPU backend.' = '字典候选可使用本地 Hashcat GPU 后端。'
        'Dictionary rules can use the local Hashcat wordlist and rule attack.' = '字典规则变形可使用本地 Hashcat 字典与规则攻击。'
        'Dictionary rules can use the local Hashcat GPU backend.' = '字典规则变形可使用本地 Hashcat GPU 后端。'
        'Capital-initial dictionary words with numeric suffixes can use the local Hashcat GPU backend.' = '首字母大写的字典词及数字后缀可使用本地 Hashcat GPU 后端。'
        'This mask can use the local Hashcat mask attack.' = '此掩码可使用本地 Hashcat 掩码攻击。'
        'This brute-force range can use the local Hashcat mask attack.' = '此穷举范围可使用本地 Hashcat 掩码攻击。'
        'No local Hashcat binary was found.' = '未找到本地 Hashcat 程序。'
        'ARCHIVE_IDENTITY_MISSING: This saved job has no archive identity and cannot be resumed safely. Create a new task.' = '保存的任务缺少归档身份，无法安全继续；请创建新任务。'
        'ARCHIVE_CHANGED: The archive changed after this local job was created; the saved recovery progress cannot be reused. Create a new task.' = '压缩包自任务创建后已发生变化，无法继续使用原有恢复进度；请创建新任务。'
    }
    if ($exact.ContainsKey($Message)) {
        return $exact[$Message]
    }

    if ($Message -match '^Preparing the local backend for coverage: (.+)\.$') {
        return ('正在准备当前覆盖范围的本地后端：{0}。' -f $Matches[1])
    }
    if ($Message -match '^Preparing the local backend for stage (.+)\.$') {
        return ('正在准备当前阶段的本地后端：{0}。' -f $Matches[1])
    }
    if ($Message -match '^Preparing local coverage: (.+)\.$') {
        return ('正在准备本地覆盖范围：{0}。' -f $Matches[1])
    }
    if ($Message -match '^Preparing local coverage for stage (.+)\.$') {
        return ('正在准备当前阶段的本地覆盖范围：{0}。' -f $Matches[1])
    }
    if ($Message -match '^Preparing local dictionary data for coverage: (.+)\.$') {
        return ('正在准备当前覆盖范围的本地字典数据：{0}。' -f $Matches[1])
    }
    if ($Message -match '^Stage (\d+)/(\d+): Preparing local dictionary: (.+)\.$') {
        return ('阶段 {0}/{1} · 正在准备本地字典：{2}' -f $Matches[1], $Matches[2], $Matches[3])
    }
    if ($Message -match '^Preparing local attack data for stage (.+)\.$') {
        return ('正在准备当前阶段的本地攻击数据：{0}。' -f $Matches[1])
    }

    if ($Message -match '^Stage (.+) skipped: (.+)$') {
        $stageName = Convert-StrategyName -Value $Matches[1]
        $reason = $Matches[2]
        $reasonText = switch ($reason) {
            'no Quick candidates were provided' { '没有提供 Quick 候选密码' }
            'the local dictionary file is missing' { '本地字典文件不存在' }
            'the mask uses ?w but the local dictionary file is missing' { '掩码使用了 ?w，但本地字典文件不存在' }
            'the brute-force length range is invalid' { '穷举长度范围无效' }
            default { $reason }
        }
        return ('已跳过“{0}”阶段：{1}。' -f $stageName, $reasonText)
    }
    if ($Message -match '^Coverage (.+) was already completed in this local job\.$') {
        return ('覆盖范围“{0}”已在此本地任务中完成，直接略过。' -f $Matches[1])
    }
    if ($Message -match '^Stopped by the user\.') {
        return '任务已由用户停止。本地断点可用于继续任务。'
    }
    if ($Message -match '^Paused locally\.') {
        return '任务已在本地暂停。可点击“继续”恢复。'
    }
    if ($Message -match '^Auto selected local Hashcat OpenCL device: (.+)\.$') {
        return ('自动选择了本地 Hashcat OpenCL 设备：{0}。' -f $Matches[1])
    }
    if ($Message -match '^Requested selected local Hashcat OpenCL device: (.+)\.$') {
        return ('已选择本地 Hashcat OpenCL 设备：{0}。' -f $Matches[1])
    }
    if ($Message -match '^John Jumbo is searching the app-owned candidate wordlist\.$') {
        return 'John Jumbo 正在搜索应用自有候选字典；已测试数量将在批量搜索完成后报告。'
    }
    if ($Message -match '^John Jumbo could not be started;') {
        return 'John Jumbo 未能启动；已回退到 NanaZip CPU 验证路径。'
    }
    if ($Message -match '^The bundled John Jumbo build did not accept') {
        return '捆绑的 John Jumbo 无法接受当前归档记录；已回退到 NanaZip CPU 验证路径。'
    }
    if ($Message -match '^The bundled John Jumbo launcher was not found') {
        return '未找到捆绑的 John Jumbo 启动器；已回退到 NanaZip CPU 验证路径。'
    }
    if ($Message -match '^Local Hashcat ended with exit code (\d+) before a verified result was produced\.$') {
        return ('本地 Hashcat 在得到已验证结果前以退出代码 {0} 结束。' -f $Matches[1])
    }
    if ($Message -match '^ZIP GPU backend is ready') {
        return 'ZIP GPU 后端已就绪。'
    }
    if ($Message -match '^7z GPU backend is ready') {
        return '7z GPU 后端已就绪。'
    }
    if ($Message -match '^ZIP GPU backend unavailable') {
        return 'ZIP GPU 后端不可用；可继续使用 CPU。'
    }
    if ($Message -match '^7z GPU backend unavailable') {
        return '7z GPU 后端不可用；可继续使用 CPU。'
    }
    if ($Message -match '^A \?w token') {
        return '掩码中包含字典词标记 ?w，当前无法自然映射到 Hashcat GPU 任务，因此使用 CPU。'
    }
    if ($Message -match '^This hybrid') {
        return '此混合结构当前无法自然映射到 Hashcat GPU 任务，因此使用 CPU。'
    }
    if ($Message -match 'CPU fallback was selected\.') {
        return '当前 GPU 后端或策略不可用，已回退到 CPU 本地验证路径。'
    }
    return $Message
}

function Update-StrategyHelp {
    $levelText = Get-SelectedValue -Control $controls.StrategyBox
    [int]$level = 0
    try { $level = [int]$levelText } catch { $level = 0 }
    $names = @('快速尝试', '常用密码', '增强恢复', '深度搜索', '完整搜索')
    if ($level -lt 1 -or $level -gt $names.Count) {
        $controls.StrategyHelpText.Text = ''
        return
    }
    $included = $names[0..($level - 1)] -join ' → '
    $controls.StrategyHelpText.Text = ('{0}级会按顺序执行：{1}。选择的级别会自动包含之前所有级别；找到密码后立即停止。' -f $level, $included)
}

function Format-LocalCount {
    param($Value)

    if ($null -eq $Value) {
        return '暂无法预估总量'
    }
    try {
        return ('{0:N0}' -f [long]$Value)
    }
    catch {
        return [string]$Value
    }
}

function Format-LocalRate {
    param($Value)

    if ($null -eq $Value) { return '等待搜索速度采样' }
    try { [double]$rate = [double]$Value } catch { return '等待搜索速度采样' }
    if ($rate -le 0) { return '等待搜索速度采样' }
    if ($rate -ge 1e9) { return ('{0:N2}B' -f ($rate / 1e9)) }
    if ($rate -ge 1e6) { return ('{0:N2}M' -f ($rate / 1e6)) }
    if ($rate -ge 1e3) { return ('{0:N2}K' -f ($rate / 1e3)) }
    return ('{0:N0}' -f $rate)
}

function Format-LocalBytes {
    param($Value)

    if ($null -eq $Value) { return '等待文件大小采样' }
    try { [double]$bytes = [double]$Value } catch { return '等待文件大小采样' }
    if ($bytes -lt 1024) { return ('{0:N0} B' -f $bytes) }
    if ($bytes -lt 1MB) { return ('{0:N1} KB' -f ($bytes / 1KB)) }
    if ($bytes -lt 1GB) { return ('{0:N1} MB' -f ($bytes / 1MB)) }
    return ('{0:N2} GB' -f ($bytes / 1GB))
}

function Format-PreparationProgress {
    param($Current, $Total, [string]$Unit)

    if ($null -eq $Current) { return '等待准备进度采样' }
    if ($Unit -eq 'Bytes') {
        return ('{0} / {1}' -f (Format-LocalBytes -Value $Current), (Format-LocalBytes -Value $Total))
    }
    if ($null -eq $Total) { return ('已处理 {0} 词条' -f (Format-LocalCount -Value $Current)) }
    return ('{0} / {1} 词条' -f (Format-LocalCount -Value $Current), (Format-LocalCount -Value $Total))
}

function Format-LocalDuration {
    param($Seconds)

    if ($null -eq $Seconds) {
        return '无法可靠估算'
    }
    try {
        [double]$value = [double]$Seconds
    }
    catch {
        return '无法可靠估算'
    }
    if ($value -lt 0) {
        return '无法可靠估算'
    }
    if ($value -lt 60) {
        return ('约 {0:N0} 秒' -f $value)
    }

    [long]$wholeSeconds = [math]::Round($value)
    [long]$hours = [math]::Floor($wholeSeconds / 3600)
    [long]$minutes = [math]::Floor(($wholeSeconds % 3600) / 60)
    [long]$remainingSeconds = $wholeSeconds % 60
    if ($hours -gt 0) {
        return ('约 {0} 小时 {1} 分钟' -f $hours, $minutes)
    }
    return ('约 {0} 分钟 {1} 秒' -f $minutes, $remainingSeconds)
}

function Reset-UiElapsedState {
    $script:LastProgressSnapshot = $null
    $script:UiElapsedRunId = ''
    $script:UiElapsedRunStartedUtc = $null
    $script:UiElapsedFrozenSeconds = $null
    $script:UiElapsedLastSeconds = 0.0
}

function Update-UiElapsedFromProgress {
    param(
        $Progress = $null,
        [string]$DisplayState = ''
    )

    if ($null -eq $Progress) { $Progress = $script:LastProgressSnapshot }
    if ($null -eq $Progress) { return }
    if ([string]::IsNullOrWhiteSpace($DisplayState)) { $DisplayState = [string]$Progress.State }

    $runId = if ($Progress.PSObject.Properties.Name -contains 'RunId') { [string]$Progress.RunId } else { '' }
    $startedUtc = $null
    if ($Progress.PSObject.Properties.Name -contains 'RunStartedUtc' -and -not [string]::IsNullOrWhiteSpace([string]$Progress.RunStartedUtc)) {
        try {
            $startedUtc = ([datetime]::Parse([string]$Progress.RunStartedUtc, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind)).ToUniversalTime()
        }
        catch { $startedUtc = $null }
    }
    $runKey = if (-not [string]::IsNullOrWhiteSpace($runId)) { $runId } elseif ($null -ne $startedUtc) { $startedUtc.ToString('o') } else { '' }
    if (-not [string]::Equals($runKey, $script:UiElapsedRunId, [System.StringComparison]::Ordinal) -or
        (($null -eq $script:UiElapsedRunStartedUtc) -xor ($null -eq $startedUtc)) -or
        ($null -ne $startedUtc -and $null -ne $script:UiElapsedRunStartedUtc -and $startedUtc -ne $script:UiElapsedRunStartedUtc)) {
        $script:UiElapsedRunId = $runKey
        $script:UiElapsedRunStartedUtc = $startedUtc
        $script:UiElapsedFrozenSeconds = $null
        $script:UiElapsedLastSeconds = 0.0
    }

    $reportedSeconds = $null
    if ($Progress.PSObject.Properties.Name -contains 'ElapsedSeconds' -and $null -ne $Progress.ElapsedSeconds) {
        try {
            [double]$reportedValue = $Progress.ElapsedSeconds
            if ($reportedValue -ge 0) { $reportedSeconds = $reportedValue }
        }
        catch { $reportedSeconds = $null }
    }
    $terminalStates = @('Paused', 'Stopped', 'Interrupted', 'Recovered', 'Exhausted', 'Failed', 'BackendUnavailable', 'NotEncrypted')
    if ($DisplayState -in $terminalStates) {
        if ($null -ne $reportedSeconds) {
            $script:UiElapsedFrozenSeconds = [math]::Max([double]$script:UiElapsedLastSeconds, $reportedSeconds)
        }
        elseif ($null -eq $script:UiElapsedFrozenSeconds -and $null -ne $startedUtc) {
            $script:UiElapsedFrozenSeconds = [math]::Max(0.0, ([datetime]::UtcNow - $startedUtc).TotalSeconds)
        }
        if ($null -ne $script:UiElapsedFrozenSeconds) {
            $script:UiElapsedLastSeconds = [double]$script:UiElapsedFrozenSeconds
            $controls.ElapsedValue.Text = Format-LocalDuration -Seconds $script:UiElapsedFrozenSeconds
        }
        return
    }

    [double]$currentSeconds = 0.0
    if ($null -ne $startedUtc) {
        $currentSeconds = [math]::Max(0.0, ([datetime]::UtcNow - $startedUtc).TotalSeconds)
    }
    elseif ($null -ne $reportedSeconds) {
        $currentSeconds = $reportedSeconds
    }
    $script:UiElapsedLastSeconds = [math]::Max([double]$script:UiElapsedLastSeconds, $currentSeconds)
    $controls.ElapsedValue.Text = Format-LocalDuration -Seconds $script:UiElapsedLastSeconds
}

function Format-LocalEta {
    param($Seconds)

    if ($null -eq $Seconds) { return '开始搜索后更新预计时间' }
    try { [double]$value = [double]$Seconds } catch { return '开始搜索后更新预计时间' }
    if ($value -lt 0) { return '开始搜索后更新预计时间' }
    if ($value -eq 0) { return '已完成' }
    if ($value -lt 1) { return '少于 1 秒' }
    return (Format-LocalDuration -Seconds $value)
}

function Format-LocalEtaRange {
    param($LowSeconds, $HighSeconds)

    if ($null -eq $LowSeconds -or $null -eq $HighSeconds) { return '无法可靠估算' }
    try {
        [double]$low = [double]$LowSeconds
        [double]$high = [double]$HighSeconds
    }
    catch {
        return '无法可靠估算'
    }
    if ($low -lt 0 -or $high -lt 0) { return '无法可靠估算' }
    if ($high -lt $low) { $high = $low }
    if ([math]::Abs($high - $low) -lt 0.5) { return (Format-LocalEta -Seconds $low) }
    $lowText = Format-LocalDuration -Seconds $low
    $highText = Format-LocalDuration -Seconds $high
    if ($lowText.StartsWith('约 ')) { $lowText = $lowText.Substring(2) }
    if ($highText.StartsWith('约 ')) { $highText = $highText.Substring(2) }
    return ('约 {0}–{1}' -f $lowText, $highText)
}

function Format-FriendlyOverallEta {
    param($Seconds)

    if ($null -eq $Seconds) { return '无法可靠估算' }
    try { [double]$value = [double]$Seconds } catch { return '无法可靠估算' }
    if ([double]::IsNaN($value) -or [double]::IsInfinity($value) -or $value -lt 0) {
        return '无法可靠估算'
    }
    if ($value -eq 0) { return '已完成' }
    if ($value -lt 45) { return '约 30 秒' }
    if ($value -lt 90) { return '约 1 分钟' }
    if ($value -lt 150) { return '约 2 分钟' }
    if ($value -lt 240) { return '约 3 分钟' }
    if ($value -lt 450) { return '约 5 分钟' }
    if ($value -lt 750) { return '约 10 分钟' }
    if ($value -lt 1125) { return '约 15 分钟' }
    if ($value -lt 2700) { return '约 30 分钟' }
    if ($value -lt 5400) { return '约 1 小时' }
    if ($value -lt 8100) { return '约 1 小时 30 分钟' }
    if ($value -lt 10800) { return '约 2 小时' }

    [long]$halfHours = [math]::Ceiling($value / 1800.0)
    [long]$hours = [math]::Floor($halfHours / 2)
    if (($halfHours % 2) -eq 1) {
        return ('约 {0} 小时 30 分钟' -f $hours)
    }
    return ('约 {0} 小时' -f $hours)
}

function Get-OverallEtaPrimaryText {
    param(
        [string]$DisplayState,
        [string]$Readiness,
        $EtaSeconds,
        $EtaLowSeconds,
        $EtaHighSeconds,
        [bool]$InvariantViolation = $false,
        [string]$Activity = '',
        [bool]$HasValidHistory = $false
    )

    if ($DisplayState -eq 'Recovered') { return '已找到密码' }
    if ($DisplayState -eq 'Exhausted') { return '已完成' }
    if ($Activity -in @('Pausing', 'Paused', 'Stopping', 'Stopped')) { return '继续搜索后更新' }
    if ($InvariantViolation) { return '正在同步…' }
    if ($Readiness -eq 'Calibrating') { return '正在校准…' }
    if ($Readiness -eq 'Preliminary') {
        $referenceSeconds = $EtaSeconds
        if ($null -ne $EtaLowSeconds -and $null -ne $EtaHighSeconds) {
            try { $referenceSeconds = ([double]$EtaLowSeconds + [double]$EtaHighSeconds) / 2.0 } catch { }
        }
        return (Format-FriendlyOverallEta -Seconds $referenceSeconds)
    }
    if ($Readiness -eq 'Stable' -and $null -ne $EtaSeconds) {
        try {
            if ([double]$EtaSeconds -ge 0) { return (Format-FriendlyOverallEta -Seconds $EtaSeconds) }
        }
        catch { }
    }
    if ($HasValidHistory) { return '正在重新校正' }
    return '开始搜索后显示'
}

function Invoke-DeviceProbe {
    [CmdletBinding()]
    param()

    if ($script:DeviceProbeState -in @('Completed', 'Failed', 'Running')) {
        return $script:DeviceProbeResult
    }

    $script:DeviceProbeState = 'Running'
    $script:DeviceProbeError = ''
    $format = if ($null -ne $script:CurrentInspection) { [string]$script:CurrentInspection.Format } else { 'Unknown' }
    $backend = $null
    $windowsDevices = @()
    try {
        $backend = Get-LocalGpuBackendStatus -Format $format -ProjectRoot $projectRoot
    }
    catch {
        $script:DeviceProbeError = $_.Exception.Message
    }
    try {
        $windowsDevices = @(Get-LocalComputeDevices)
    }
    catch {
        if ([string]::IsNullOrWhiteSpace($script:DeviceProbeError)) { $script:DeviceProbeError = $_.Exception.Message }
        $windowsDevices = @()
    }
    if ($null -eq $backend) {
        $backend = [pscustomobject]@{
            HashcatPath           = $null
            Zip2JohnPath          = $null
            SevenZipExtractorPath = $null
            Devices               = @()
            AdapterAvailable      = $false
            Ready                 = $false
            Message               = 'Local GPU discovery did not complete; CPU remains available.'
        }
    }
    $script:DeviceProbeResult = [pscustomobject]@{
        Backend = $backend
        WindowsDevices = $windowsDevices
    }
    $script:DeviceProbeState = if ([string]::IsNullOrWhiteSpace($script:DeviceProbeError)) { 'Completed' } else { 'Failed' }
    return $script:DeviceProbeResult
}

function Get-DeviceBackendMessage {
    param(
        [Parameter(Mandatory = $true)]$Probe
    )

    $backend = $Probe.Backend
    $format = if ($null -ne $script:CurrentInspection) { [string]$script:CurrentInspection.Format } else { 'Unknown' }
    $formatKey = $format.ToUpperInvariant()
    if ($formatKey -notin @('ZIP', '7Z')) {
        return [string]$backend.Message
    }

    # The initial probe can run before an archive is selected and therefore
    # reports Unknown. Re-project that cached raw result after selection;
    # this does not invoke Hashcat or enumerate devices again.
    $openClReady = (-not [string]::IsNullOrWhiteSpace([string]$backend.HashcatPath) -and @($backend.Devices).Count -gt 0)
    if ($formatKey -eq 'ZIP') {
        if ([string]::IsNullOrWhiteSpace([string]$backend.HashcatPath)) {
            return 'ZIP GPU backend unavailable: the bundled local Hashcat executable was not found.'
        }
        if ([string]::IsNullOrWhiteSpace([string]$backend.Zip2JohnPath)) {
            return 'ZIP GPU backend unavailable: the bundled local zip2john extractor was not found.'
        }
        if (-not $openClReady) {
            return 'ZIP GPU backend unavailable: Hashcat could not initialize a local OpenCL GPU.'
        }
        return 'ZIP GPU backend is ready for WinZip AES archives. Legacy ZipCrypto remains on the CPU path.'
    }

    if ([string]::IsNullOrWhiteSpace([string]$backend.HashcatPath)) {
        return '7z GPU backend unavailable: the bundled local Hashcat executable was not found.'
    }
    if ([string]::IsNullOrWhiteSpace([string]$backend.SevenZipExtractorPath)) {
        return '7z GPU backend unavailable: the bundled local 7z2hashcat extractor was not found.'
    }
    if (-not $openClReady) {
        return '7z GPU backend unavailable: Hashcat could not initialize a local OpenCL GPU.'
    }
    return '7z GPU backend is ready for locally extracted 7-Zip AES recovery records.'
}

function Update-DeviceInfo {
    param($Probe = $null)

    if ($null -eq $Probe) { $Probe = Invoke-DeviceProbe }
    $backend = $Probe.Backend
    $devices = @($Probe.WindowsDevices)
    $gpuDescriptions = @($devices | Where-Object { $_.Kind -eq 'GPU' } | ForEach-Object { Convert-ComputeDeviceName -Value $_.ChoiceName })
    $backendDescriptions = @($backend.Devices | ForEach-Object {
            ('{0}（Hashcat OpenCL 设备 #{1}，可用）' -f $_.Name, $_.DeviceId)
        })
    $backendText = if ($backendDescriptions.Count -gt 0) { $backendDescriptions -join '；' } else { '当前本地后端未初始化可用 GPU' }
    $windowsText = if ($gpuDescriptions.Count -gt 0) { $gpuDescriptions -join '；' } else { 'Windows 未报告 GPU' }
    $availableDevices = New-Object 'System.Collections.Generic.List[string]'
    [void]$availableDevices.Add('CPU')
    foreach ($device in @($backend.Devices | Sort-Object @{ Expression = {
                    if ([string]$_.Vendor -eq 'NVIDIA') { 0 }
                    elseif ([string]$_.Vendor -eq 'AMD') { 1 }
                    else { 2 }
                }
            }, @{ Expression = { [int]$_.DeviceId } }, Name)) {
        [void]$availableDevices.Add(('{0} (#{1})' -f $device.Name, $device.DeviceId))
    }
    $controls.DeviceInfoText.Text = '可用：' + ($availableDevices.ToArray() -join ' · ')
    if (-not [string]::IsNullOrWhiteSpace([string]$script:DeviceSelectionWarning)) {
        $controls.DeviceInfoText.Text += ' · ' + [string]$script:DeviceSelectionWarning
    }
    $backendMessage = Get-DeviceBackendMessage -Probe $Probe
    $controls.AdvancedDeviceInfoText.Text = ('详细设备信息：Windows 设备：{0}。Hashcat 设备：{1}。NanaZip CPU 验证器已就绪。GPU 后端：{2}。' -f $windowsText, $backendText, (Convert-UiMessage -Message $backendMessage))
}

function Populate-DeviceChoices {
    param($Probe = $null)

    if ($null -eq $Probe) { $Probe = Invoke-DeviceProbe }
    $backend = $Probe.Backend
    $selectedValue = Get-SelectedValue -Control $controls.DeviceBox
    $controls.DeviceBox.Items.Clear()
    [void](Add-LocalizedComboChoice -Control $controls.DeviceBox -DisplayText 'Auto（推荐）' -Value 'Auto')
    [void](Add-LocalizedComboChoice -Control $controls.DeviceBox -DisplayText '仅使用 CPU' -Value 'CPU')
    $devices = @($backend.Devices | Where-Object { [string]$_.Type -eq 'GPU' } | Sort-Object @{ Expression = {
            if ([string]$_.Vendor -eq 'NVIDIA') { 0 }
                    elseif ([string]$_.Vendor -eq 'AMD') { 1 }
                    else { 2 }
                }
            }, @{ Expression = { [int]$_.DeviceId } }, Name)
    foreach ($device in $devices) {
        $metadata = [pscustomobject]@{
            Backend = 'HashcatOpenCL'
            Vendor = [string]$device.Vendor
            Name = [string]$device.Name
            LastDeviceId = [int]$device.DeviceId
        }
        [void](Add-LocalizedComboChoice -Control $controls.DeviceBox -DisplayText ('{0} (#{1})' -f $device.Name, $device.DeviceId) -Value ('GPU:{0}' -f $device.DeviceId) -Metadata $metadata)
    }
    $script:DeviceChoicesPopulated = $true
    if ([string]::IsNullOrWhiteSpace($selectedValue) -or -not (Set-SelectedValue -Control $controls.DeviceBox -Value $selectedValue)) {
        [void](Set-SelectedValue -Control $controls.DeviceBox -Value 'Auto')
    }
    Update-DeviceInfo -Probe $Probe
}

function Ensure-DeviceChoicesReady {
    $probe = Invoke-DeviceProbe
    if (-not $script:DeviceChoicesPopulated) {
        Populate-DeviceChoices -Probe $probe
    }
    return $probe
}

function Invoke-DeferredStartup {
    [CmdletBinding()]
    param()

    if ($script:DeferredStartupStarted) { return }
    $script:DeferredStartupStarted = $true
    try { $startupRuntimeCleanup = @(Cleanup-StaleRecoveryRuntime -RuntimeRoot $runtimeRoot) } catch { $startupRuntimeCleanup = @() }
    try { $startupJobCleanup = @(Cleanup-TerminalRecoveryJobs -JobsRoot $jobsRoot) } catch { $startupJobCleanup = @() }
    if ($startupRuntimeCleanup.Count -gt 0) {
        Write-UiLog ('已清理 {0} 个无活动任务的旧 Runtime 临时目录。' -f $startupRuntimeCleanup.Count)
    }
    if ($startupJobCleanup.Count -gt 0) {
        Write-UiLog ('已清理 {0} 个超过保留期限的已完成本地任务。' -f $startupJobCleanup.Count)
    }
    try {
        [void](Ensure-DeviceChoicesReady)
        if ($script:DeviceProbeState -eq 'Failed') {
            Write-UiLog '本机 GPU 检测未能完整完成，已保留 Auto 和 CPU 选项；开始任务时仍会使用现有本地后端判断。'
        }
    }
    catch {
        Write-UiLog ('本机 GPU 检测失败，已保留 Auto 和 CPU 选项：' + (Convert-UiMessage -Message $_.Exception.Message))
    }
}

function Restore-SavedDeviceChoice {
    param([Parameter(Mandatory = $true)]$Job)

    $script:DeviceSelectionWarning = ''
    $preference = if ($Job.PSObject.Properties.Name -contains 'DevicePreference') { [string]$Job.DevicePreference } else { 'Auto' }
    if ([string]::IsNullOrWhiteSpace($preference)) { $preference = 'Auto' }

    if ($preference -eq 'GPU') {
        $savedGpu = if ($Job.PSObject.Properties.Name -contains 'SelectedGpu') { $Job.SelectedGpu } else { $null }
        $savedVendor = [string](Get-UiObjectPropertyValue -Object $savedGpu -Name 'Vendor' -Default '')
        $savedName = [string](Get-UiObjectPropertyValue -Object $savedGpu -Name 'Name' -Default '')
        $matches = @($controls.DeviceBox.Items | Where-Object {
                $metadata = if ($_ -is [System.Windows.Controls.ComboBoxItem]) { $_.DataContext } else { $null }
                $metadataVendor = [string](Get-UiObjectPropertyValue -Object $metadata -Name 'Vendor' -Default '')
                $metadataName = [string](Get-UiObjectPropertyValue -Object $metadata -Name 'Name' -Default '')
                -not [string]::IsNullOrWhiteSpace($savedVendor) -and -not [string]::IsNullOrWhiteSpace($savedName) -and
                [string]::Equals($metadataVendor, $savedVendor, [System.StringComparison]::Ordinal) -and
                [string]::Equals($metadataName, $savedName, [System.StringComparison]::Ordinal)
            })
        if ($matches.Count -eq 1) {
            $controls.DeviceBox.SelectedItem = $matches[0]
            return
        }
        $savedLastDeviceId = Get-UiObjectPropertyValue -Object $savedGpu -Name 'LastDeviceId' -Default $null
        if ($matches.Count -gt 1 -and $null -ne $savedLastDeviceId) {
            [int]$lastDeviceId = -1
            try { $lastDeviceId = [int]$savedLastDeviceId } catch { $lastDeviceId = -1 }
            $idMatches = @($matches | Where-Object { [int](Get-UiObjectPropertyValue -Object $_.DataContext -Name 'LastDeviceId' -Default -1) -eq $lastDeviceId })
            if ($idMatches.Count -eq 1) {
                $controls.DeviceBox.SelectedItem = $idMatches[0]
                return
            }
        }
        [void](Set-SelectedValue -Control $controls.DeviceBox -Value 'CPU')
        if ([string]::IsNullOrWhiteSpace($savedName)) { $savedName = '未记录设备' }
        $script:DeviceSelectionWarning = ('保存的 GPU 不可用，已回退 CPU：' + $savedName)
        Write-UiLog $script:DeviceSelectionWarning
        return
    }

    if (Set-SelectedValue -Control $controls.DeviceBox -Value $preference) { return }

    # Keep vendor-only preferences readable for old job files. This item is
    # added only while opening an old task; newly created jobs always use an
    # exact GPU identity or Auto/CPU.
    if ($preference -match '(?i)\sGPU$') {
        [void](Add-LocalizedComboChoice -Control $controls.DeviceBox -DisplayText ($preference + '（旧任务兼容）') -Value $preference)
        [void](Set-SelectedValue -Control $controls.DeviceBox -Value $preference)
        return
    }

    [void](Set-SelectedValue -Control $controls.DeviceBox -Value 'CPU')
    $script:DeviceSelectionWarning = ('保存的设备选择无法识别，已回退 CPU：' + $preference)
    Write-UiLog $script:DeviceSelectionWarning
}

function Get-QuickCandidateList {
    $items = New-Object 'System.Collections.Generic.List[string]'
    foreach ($line in ($controls.QuickCandidatesBox.Text -split "`r?`n")) {
        if (-not [string]::IsNullOrWhiteSpace($line)) {
            $items.Add($line)
        }
    }
    return @(Get-CanonicalQuickCandidates -Candidates $items.ToArray())
}

function Get-JobFromControls {
    $characterSet = Get-SelectedValue -Control $controls.CharacterSetBox
    [int]$recoveryLevel = 0
    try { $recoveryLevel = [int](Get-SelectedValue -Control $controls.StrategyBox) } catch { $recoveryLevel = 0 }
    if ($recoveryLevel -lt 1 -or $recoveryLevel -gt 5) {
        throw '请选择 1 到 5 级恢复级别。'
    }
    $mask = [string]$controls.MaskBox.Text
    $dictionaryPath = $controls.DictionaryPathBox.Text.Trim()
    $maskIdentity = Get-CustomMaskCoverageIdentity -Job ([pscustomobject]@{ Mask = $mask; DictionaryPath = $dictionaryPath })
    $maskDictionaryIdentity = if ([bool]$maskIdentity.HasWordToken) {
        [ordered]@{
            Path = [string]$maskIdentity.DictionaryPath
            Size = $maskIdentity.DictionarySize
            LastWriteTimeUtc = $maskIdentity.DictionaryLastWriteTimeUtc
        }
    }
    else { $null }
    $deviceSelection = Get-SelectedDeviceJobSelection
    return [ordered]@{
        SchemaVersion     = 5
        ArchivePath       = $controls.ArchivePathBox.Text.Trim()
        RecoveryLevel     = $recoveryLevel
        DevicePreference  = [string]$deviceSelection.Preference
        SelectedGpu       = $deviceSelection.SelectedGpu
        QuickCandidates   = @(Get-QuickCandidateList)
        QuickCoverageRevision = 1
        QuickCoverageLegacy = $false
        TryEmptyPassword  = [bool]$controls.TryEmptyPasswordBox.IsChecked
        DictionaryPath    = $dictionaryPath
        Mask              = $mask
        CustomMaskCoverageRevision = if ([string]::IsNullOrEmpty($mask)) { 0 } else { 1 }
        CustomMaskDictionaryIdentity = $maskDictionaryIdentity
        CharacterSet      = $characterSet
        CustomCharacters  = $controls.CustomCharacterSetBox.Text
        MinLength         = $controls.MinLengthBox.Text.Trim()
        MaxLength         = $controls.MaxLengthBox.Text.Trim()
        UiCulture         = [System.Globalization.CultureInfo]::CurrentUICulture.Name
        RecoveryPlanYear  = (Get-Date).Year
        ArchiveIdentity   = (Get-ArchiveIdentity -Path $controls.ArchivePathBox.Text.Trim())
        CreatedUtc        = [datetime]::UtcNow.ToString('o')
    }
}

function Inspect-SelectedArchive {
    $archivePath = $controls.ArchivePathBox.Text.Trim()
    $script:CurrentInspection = $null
    Set-ArchiveDisplayState -HasValidArchive:$false
    Update-TaskControls
    if ([string]::IsNullOrWhiteSpace($archivePath)) {
        throw '请先选择本地压缩包。'
    }

    $sevenZip = Resolve-SevenZip
    $inspection = Get-ArchiveInspection -ArchivePath $archivePath -SevenZip $sevenZip
    $processableFormats = @('ZIP', '7Z', 'RAR', 'TAR', 'GZ', 'TGZ', 'BZ2', 'XZ')
    $normalizedFormat = ([string]$inspection.Format).ToUpperInvariant()
    $hasUsableMetadata = ($inspection.ListingExitCode -eq 0 -or [string]$inspection.EncryptionState -eq 'Yes')
    if ($processableFormats -notcontains $normalizedFormat -or -not $hasUsableMetadata) {
        throw '所选文件无法识别为可处理的本地压缩包。'
    }

    $script:CurrentInspection = $inspection
    $methods = if (@($inspection.Methods).Count -gt 0) { @($inspection.Methods) -join ' / ' } else { '方法未能识别' }
    $encryption = switch ([string]$inspection.EncryptionState) {
        'Yes' { '已加密' }
        'No' { '未加密' }
        default { '加密状态未能识别' }
    }
    $metadataStatus = if ($inspection.ListingExitCode -eq 0) { '已在本机检查' } else { '仅能在本机部分检查' }
    $controls.ArchiveFileNameText.Text = [System.IO.Path]::GetFileName($archivePath)
    $controls.ArchiveInfoText.Text = ('{0} · {1} · {2}' -f $inspection.Format, $methods, $encryption)
    $controls.ArchiveInfoText.ToolTip = ('格式：{0}；加密状态：{1}；方法：{2}；元数据状态：{3}' -f $inspection.Format, $encryption, $methods, $metadataStatus)
    Update-DeviceInfo
    Write-UiLog ('已在本机检查压缩包：格式={0}，已加密={1}。' -f $inspection.Format, $encryption)
    Set-ArchiveDisplayState -HasValidArchive:$true
    Update-TaskControls
    return $inspection
}

function Get-CurrentJobRuntimeActivity {
    if ([string]::IsNullOrWhiteSpace($script:CurrentJobDirectory)) {
        return [pscustomobject]@{ Known = $true; Active = $false; Reason = ''; WorkerProcessIds = @(); HashcatProcessIds = @() }
    }

    $jobId = [string]$script:CurrentJobId
    if ([string]::IsNullOrWhiteSpace($jobId)) {
        $jobPath = Join-Path $script:CurrentJobDirectory 'job.json'
        if (-not (Test-Path -LiteralPath $jobPath -PathType Leaf)) {
            return [pscustomobject]@{ Known = $false; Active = $false; Reason = '当前任务缺少 job.json，无法确认 Worker 状态。'; WorkerProcessIds = @(); HashcatProcessIds = @() }
        }
        try {
            $job = Read-LocalJson -Path $jobPath
            $jobId = if ($job.PSObject.Properties.Name -contains 'JobId') { [string]$job.JobId } else { '' }
            if ([string]::IsNullOrWhiteSpace($jobId)) {
                $jobId = [System.IO.Path]::GetFileName(([System.IO.Path]::GetFullPath($script:CurrentJobDirectory)).TrimEnd('\'))
            }
            $script:CurrentJobId = $jobId
        }
        catch {
            return [pscustomobject]@{ Known = $false; Active = $false; Reason = $_.Exception.Message; WorkerProcessIds = @(); HashcatProcessIds = @() }
        }
    }
    try {
        return Get-RecoveryRuntimeActivity -JobId $jobId -JobDirectory $script:CurrentJobDirectory -RuntimeRoot $runtimeRoot
    }
    catch {
        return [pscustomobject]@{ Known = $false; Active = $false; Reason = $_.Exception.Message; WorkerProcessIds = @(); HashcatProcessIds = @() }
    }
}

function Wait-CurrentJobRuntimeInactive {
    param([int]$TimeoutSeconds = 5)

    $deadline = [datetime]::UtcNow.AddSeconds([math]::Max(0, $TimeoutSeconds))
    $activity = $null
    do {
        $activity = Get-CurrentJobRuntimeActivity
        if (-not $activity.Known -or -not $activity.Active) { return $activity }
        Start-Sleep -Milliseconds 100
    } while ([datetime]::UtcNow -lt $deadline)
    return $activity
}

function Get-WorkerIsRunning {
    if ($null -ne $script:CurrentWorker) {
        try {
            if (-not $script:CurrentWorker.HasExited) { return $true }
        }
        catch { }
    }
    $activity = Get-CurrentJobRuntimeActivity
    return [bool]($activity.Known -and $activity.Active)
}

function Assert-NoActiveArchiveJob {
    param([Parameter(Mandatory = $true)][string]$ArchivePath)

    foreach ($match in @(Get-RecoveryJobDirectoriesForArchive -JobsRoot $jobsRoot -ArchivePath $ArchivePath)) {
        $activity = Get-RecoveryRuntimeActivity -JobId ([string]$match.JobId) -JobDirectory ([string]$match.JobDirectory) -RuntimeRoot $runtimeRoot
        if (-not $activity.Known) {
            throw ('无法确认压缩包任务 {0} 当前是否正在运行，已停止启动。' -f [string]$match.JobId)
        }
        if ($activity.Active) {
            throw ('当前压缩包已有本地 Worker 或 Hashcat 正在运行（任务 {0}），不会启动第二个 Worker。' -f [string]$match.JobId)
        }
    }
}

function Test-IsFinalCumulativeExhausted {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Progress
    )

    if ([string]$Progress.State -ne 'Exhausted') { return $false }
    if ($Progress.PSObject.Properties.Name -notcontains 'RequestedCoverage') { return $true }

    $requested = @($Progress.RequestedCoverage | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($requested.Count -eq 0) { return -not (Get-WorkerIsRunning) }

    $finished = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
    if ($Progress.PSObject.Properties.Name -contains 'CompletedCoverageIds') {
        foreach ($coverageId in @($Progress.CompletedCoverageIds)) {
            if ($null -ne $coverageId -and -not [string]::IsNullOrWhiteSpace([string]$coverageId)) {
                [void]$finished.Add([string]$coverageId)
            }
        }
    }
    if ($Progress.PSObject.Properties.Name -contains 'SkippedStages') {
        foreach ($skipped in @($Progress.SkippedStages)) {
            if ($null -ne $skipped -and $skipped.PSObject.Properties.Name -contains 'CoverageId' -and
                -not [string]::IsNullOrWhiteSpace([string]$skipped.CoverageId)) {
                [void]$finished.Add([string]$skipped.CoverageId)
            }
        }
    }

    foreach ($coverageId in $requested) {
        if (-not $finished.Contains([string]$coverageId)) { return $false }
    }
    return $true
}

function Update-TaskControls {
    param([string]$State = '')

    if ([string]::IsNullOrWhiteSpace($State) -and -not [string]::IsNullOrWhiteSpace($script:CurrentJobDirectory)) {
        $progressPath = Join-Path $script:CurrentJobDirectory 'progress.json'
        if (Test-Path -LiteralPath $progressPath -PathType Leaf) {
            try { $State = [string](Read-LocalJson -Path $progressPath).State } catch { $State = '' }
        }
    }

    $runtimeActivity = Get-CurrentJobRuntimeActivity
    if ($State -in @('Starting', 'Running', 'Pausing', 'Stopping') -and $runtimeActivity.Known -and -not $runtimeActivity.Active) {
        $State = 'Interrupted'
    }
    $visible = [System.Windows.Visibility]::Visible
    $collapsed = [System.Windows.Visibility]::Collapsed
    $isPaused = $State -eq 'Paused'
    $isStopped = $State -eq 'Stopped'
    $isRuntimeActive = [bool]($runtimeActivity.Known -and $runtimeActivity.Active)
    $isCurrentWorkerActive = $false
    if ($null -ne $script:CurrentWorker) {
        try { $isCurrentWorkerActive = -not $script:CurrentWorker.HasExited } catch { $isCurrentWorkerActive = $false }
    }
    $isActive = $State -in @('Starting', 'Running', 'Pausing', 'Stopping') -or $isRuntimeActive -or $isCurrentWorkerActive

    $hasValidArchive = ($null -ne $script:CurrentInspection -and -not [string]::IsNullOrWhiteSpace($controls.ArchivePathBox.Text))
    $controls.ResetCurrentArchiveButton.IsEnabled = $hasValidArchive -and -not $isActive
    $controls.ClearPerformanceProfilesButton.IsEnabled = $true
    $controls.StartButton.IsEnabled = $hasValidArchive -and -not ($isActive -and -not $isPaused)
    $isInterrupted = $State -eq 'Interrupted'
    if ($isPaused -or $isStopped -or $isInterrupted) {
        $controls.PauseButton.Visibility = $collapsed
        $controls.ResumeButton.Visibility = $visible
        $controls.ResumeButton.IsEnabled = $true
        $controls.StopButton.Visibility = if ($isPaused) { $visible } else { $collapsed }
        $controls.StopButton.IsEnabled = $isPaused
        return
    }

    if ($isActive) {
        $controls.PauseButton.Visibility = $visible
        $controls.PauseButton.IsEnabled = $State -in @('', 'Starting', 'Running')
        $controls.ResumeButton.Visibility = $collapsed
        $controls.ResumeButton.IsEnabled = $false
        $controls.StopButton.Visibility = $visible
        $controls.StopButton.IsEnabled = $true
        return
    }

    $controls.PauseButton.Visibility = $collapsed
    $controls.PauseButton.IsEnabled = $false
    $controls.ResumeButton.Visibility = $collapsed
    $controls.ResumeButton.IsEnabled = $false
    $controls.StopButton.Visibility = $collapsed
    $controls.StopButton.IsEnabled = $false
}

function Select-ArchivePath {
    param([Parameter(Mandatory = $true)][string]$Path)

    try {
        if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
            throw '所选压缩包不存在。'
        }
        $controls.ArchivePathBox.Text = $Path
        $controls.ArchiveFileNameText.Text = [System.IO.Path]::GetFileName($Path)
        $controls.ArchiveInfoText.Text = '正在本机检查文件…'
        $controls.ArchiveInfoText.ToolTip = $null
        $script:CurrentInspection = $null
        Reset-UiElapsedState
        Set-ArchiveDisplayState -HasValidArchive:$false
        Update-TaskControls
        $null = Inspect-SelectedArchive
    }
    catch {
        Clear-SelectedArchive
        throw
    }
}

function Get-DroppedArchivePath {
    param([Parameter(Mandatory = $true)][string[]]$Paths)

    $extensions = @('.zip', '.7z', '.rar', '.tar', '.gz', '.tgz', '.bz2', '.xz')
    $validPaths = @($Paths | Where-Object {
            (Test-Path -LiteralPath $_ -PathType Leaf) -and
            $extensions -contains ([System.IO.Path]::GetExtension([string]$_).ToLowerInvariant())
        })
    if ($validPaths.Count -eq 0) {
        throw '请拖入一个 ZIP、7z、RAR 或其他受支持的本地压缩包。'
    }
    if ($validPaths.Count -gt 1) {
        Write-UiLog ('一次只支持一个恢复任务，已使用第一个有效压缩包：' + [System.IO.Path]::GetFileName([string]$validPaths[0]))
    }
    return [string]$validPaths[0]
}

function Handle-ArchiveDrop {
    param([Parameter(Mandatory = $true)]$EventArgs)

    try {
        if (-not $EventArgs.Data.GetDataPresent([System.Windows.DataFormats]::FileDrop)) {
            throw '拖入内容不是本地文件。'
        }
        $paths = [string[]]$EventArgs.Data.GetData([System.Windows.DataFormats]::FileDrop)
        $path = Get-DroppedArchivePath -Paths $paths
        Select-ArchivePath -Path $path
    }
    catch {
        Clear-SelectedArchive
        Show-UiError $_.Exception.Message
    }
    finally {
        $EventArgs.Handled = $true
        $controls.ArchiveDropZone.Background = [System.Windows.Media.Brushes]::White
        $controls.ArchiveDropZone.BorderBrush = New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.Color]::FromRgb(175, 198, 224))
    }
}

function Start-WorkerProcess {
    param([switch]$ResumeJob)

    if ([string]::IsNullOrWhiteSpace($script:CurrentJobDirectory)) {
        throw '尚未选择本地任务。'
    }

    $jobPath = Join-Path $script:CurrentJobDirectory 'job.json'
    if (-not (Test-Path -LiteralPath $jobPath -PathType Leaf)) {
        throw '当前任务缺少 job.json，无法安全启动 Worker。'
    }
    if ([string]::IsNullOrWhiteSpace($script:CurrentJobId)) {
        try {
            $savedJob = Read-LocalJson -Path $jobPath
            $script:CurrentJobId = if ($savedJob.PSObject.Properties.Name -contains 'JobId') { [string]$savedJob.JobId } else { '' }
        }
        catch {
            throw ('无法读取当前任务的 JobId：' + $_.Exception.Message)
        }
    }
    if ([string]::IsNullOrWhiteSpace($script:CurrentJobId)) {
        $script:CurrentJobId = [System.IO.Path]::GetFileName(([System.IO.Path]::GetFullPath($script:CurrentJobDirectory)).TrimEnd('\'))
    }
    $activity = Get-CurrentJobRuntimeActivity
    if (-not $activity.Known) {
        throw ('无法确认当前 Job 是否已有 Worker，已停止启动：' + [string]$activity.Reason)
    }
    if ($activity.Active) {
        throw '当前 Job 已有 Worker 或 Hashcat 正在运行，不会启动第二个 Worker。'
    }

    $workerPath = Join-Path $PSScriptRoot 'RecoveryWorker.ps1'
    $arguments = @(
        '-NoProfile',
        '-ExecutionPolicy', 'Bypass',
        '-File', ('"{0}"' -f $workerPath),
        '-JobDirectory', ('"{0}"' -f $script:CurrentJobDirectory)
    )
    if ($ResumeJob) { $arguments += '-Resume' }
    $script:CurrentWorker = Start-Process -FilePath (Resolve-WindowsPowerShell) -ArgumentList $arguments -WindowStyle Hidden -PassThru
}

function Reset-LiveTaskDisplay {
    Reset-UiElapsedState
    $script:LastProgressUpdated = ''
    $controls.StateValue.Text = '正在启动'
    $controls.StageValue.Text = '等待阶段信息'
    $controls.CoverageValue.Text = '等待当前范围'
    $controls.EngineValue.Text = '尚未启动本地后端'
    $controls.DeviceValue.Text = '尚未启动'
    $controls.ProgressMetricLabel.Text = '准备进度'
    $controls.CandidatesValue.Text = '等待准备开始'
    $controls.SpeedLabel.Text = '准备速度'
    $controls.SpeedValue.Text = '等待准备采样'
    $controls.ElapsedValue.Text = '尚未开始'
    $controls.EstimatedRemainingValue.Text = '准备阶段尚未开始'
    $controls.WorstCaseValue.Text = '准备完成后估算'
    $controls.ProgressBarLabel.Text = '准备进度'
    $controls.SearchProgressBar.IsIndeterminate = $true
    $controls.SearchProgressBar.Value = 0
    $controls.ProgressPercentValue.Text = '等待本地准备进度采样…'
    $controls.ProgressMessageText.Text = '正在准备本地恢复任务。压缩包数据不会离开此电脑。'
    $controls.OverallProgressBar.IsIndeterminate = $false
    $controls.OverallProgressBar.Value = 0
    $controls.OverallProgressBar.Foreground = New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.Color]::FromRgb(170, 178, 188))
    $controls.OverallProgressPercent.Text = '—'
    $controls.OverallCandidatesTestedLabel.Text = '已累计测试'
    $controls.OverallCandidatesTestedValue.Text = '等待开始'
    $controls.OverallCandidatesRemainingLabel.Text = '剩余待尝试'
    $controls.OverallCandidatesRemainingValue.Text = '准备后显示'
    $controls.OverallSpeedValue.Text = '开始搜索后显示'
    $controls.OverallEtaValue.Text = '开始搜索后显示'
    $controls.OverallProgressSummary.Text = '准备后显示'
    $controls.OverallStageValue.Text = '等待开始'
    $controls.OverallCoverageValue.Text = '等待开始'
    $controls.OverallProgressCurrent.Text = '等待开始'
    $controls.OverallProgressHelper.Text = ''
    $controls.OverallProgressHelper.Visibility = [System.Windows.Visibility]::Collapsed
    $controls.ResultValue.Text = ''
    $controls.ResultCard.Visibility = [System.Windows.Visibility]::Collapsed
}

function Start-NewJob {
    try {
        if ($null -eq $script:CurrentInspection -or [string]::IsNullOrWhiteSpace($controls.ArchivePathBox.Text)) {
            throw '请先选择并识别有效的本地压缩包。'
        }
        if (Get-WorkerIsRunning) {
            throw '已有本地恢复任务正在运行。请先暂停或停止该任务，再开始新的任务。'
        }

        [void](Ensure-DeviceChoicesReady)
        $null = Inspect-SelectedArchive
        $controlJob = [pscustomobject](Get-JobFromControls)
        Test-RecoveryJobConfiguration -Job $controlJob
        Assert-NoActiveArchiveJob -ArchivePath ([string]$controlJob.ArchivePath)

        $requestedLevel = [int]$controlJob.RecoveryLevel
        $reuseExistingJob = $false
        $resumeUpgrade = $false
        $upgradeDecision = $null
        if (-not [string]::IsNullOrWhiteSpace($script:CurrentJobDirectory) -and
            (Test-Path -LiteralPath (Join-Path $script:CurrentJobDirectory 'job.json') -PathType Leaf) -and
            -not (Get-WorkerIsRunning)) {
            try {
                $existingJob = Read-LocalJson -Path (Join-Path $script:CurrentJobDirectory 'job.json')
                $existingLevel = Get-RecoveryLevel -Job $existingJob
                $sameArchive = ($existingJob.PSObject.Properties.Name -contains 'ArchiveIdentity' -and
                    (Test-ArchiveIdentityMatch -Expected $existingJob.ArchiveIdentity -Actual $controlJob.ArchiveIdentity))
                if ($sameArchive -and $requestedLevel -gt $existingLevel) {
                    $existingProgress = $null
                    $progressPath = Join-Path $script:CurrentJobDirectory 'progress.json'
                    if (Test-Path -LiteralPath $progressPath -PathType Leaf) {
                        try { $existingProgress = Read-LocalJson -Path $progressPath } catch { $existingProgress = $null }
                    }
                    $availableCoverageIds = New-Object 'System.Collections.Generic.List[string]'
                    for ($stageNumber = 1; $stageNumber -le $requestedLevel; $stageNumber++) {
                        foreach ($planItem in @(Get-RecoveryPlanItems -Job $controlJob -StageNumber $stageNumber)) {
                            if (-not $availableCoverageIds.Contains([string]$planItem.CoverageId)) {
                                [void]$availableCoverageIds.Add([string]$planItem.CoverageId)
                            }
                        }
                    }
                    $upgradeDecision = Get-RecoveryLevelUpgradeIntent -ExistingJob $existingJob -NewControlJob $controlJob -ExistingProgress $existingProgress -JobDirectory $script:CurrentJobDirectory -AvailableCoverageIds $availableCoverageIds.ToArray()
                    if ([string]$upgradeDecision.Intent -in @('BlockedRecovered', 'BlockedNotEncrypted')) {
                        throw ([string]$upgradeDecision.Message)
                    }
                    $reuseExistingJob = [bool]$upgradeDecision.CanReuseExistingJob
                    $resumeUpgrade = [bool]$upgradeDecision.ResumeCurrentCoverage
                }
            }
            catch {
                if ($null -ne $upgradeDecision -and [string]$upgradeDecision.Intent -in @('BlockedRecovered', 'BlockedNotEncrypted')) {
                    throw
                }
                $reuseExistingJob = $false
            }
        }
        if (-not $reuseExistingJob) {
            $script:CurrentJobDirectory = Join-Path $jobsRoot ([guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Path $script:CurrentJobDirectory | Out-Null
        }
        if ($reuseExistingJob) {
            $merged = Merge-RecoveryJobForLevelUpgrade -ExistingJob $existingJob -NewControlJob $controlJob
            $job = [ordered]@{}
            foreach ($property in $merged.PSObject.Properties) { $job[$property.Name] = $property.Value }
        }
        else {
            $job = [ordered]@{}
            foreach ($property in $controlJob.PSObject.Properties) { $job[$property.Name] = $property.Value }
            $job['JobId'] = [System.IO.Path]::GetFileName($script:CurrentJobDirectory)
        }
        $script:CurrentJobId = [string]$job.JobId
        if ($reuseExistingJob) {
            foreach ($flag in @('pause.flag', 'stop.flag')) {
                $flagPath = Join-Path $script:CurrentJobDirectory $flag
                if (Test-Path -LiteralPath $flagPath -PathType Leaf) { Remove-Item -LiteralPath $flagPath -Force }
            }
        }
        Write-LocalJsonAtomic -Path (Join-Path $script:CurrentJobDirectory 'job.json') -Value $job
        # A level upgrade keeps the persistent JobId. Paused/stopped work with a
        # valid current checkpoint resumes it; terminal upgrades start only the
        # newly requested coverage items.
        Reset-LiveTaskDisplay
        Start-WorkerProcess -ResumeJob:$resumeUpgrade
        Update-TaskControls -State 'Starting'
        Write-UiLog '已启动新的本地恢复任务。'
    }
    catch {
        if ($null -eq $script:CurrentInspection) {
            Clear-SelectedArchive
        }
        Show-UiError $_.Exception.Message
    }
}

function Pause-CurrentJob {
    if ([string]::IsNullOrWhiteSpace($script:CurrentJobDirectory)) {
        Show-UiError '没有可暂停的本地任务。'
        return
    }

    $activity = Get-CurrentJobRuntimeActivity
    if (-not $activity.Known) {
        Show-UiError ('无法确认当前 Worker 状态：' + [string]$activity.Reason)
        return
    }
    if (-not $activity.Active) {
        Show-UiError '当前 Worker 已退出，任务已中断；请点击“继续”使用现有断点。'
        Update-TaskControls -State 'Interrupted'
        return
    }
    [System.IO.File]::WriteAllText((Join-Path $script:CurrentJobDirectory 'pause.flag'), 'pause')
    Write-UiLog '已请求暂停。Worker 会在当前本地候选测试完成后暂停。'
}

function Resume-CurrentJob {
    if ([string]::IsNullOrWhiteSpace($script:CurrentJobDirectory)) {
        Show-UiError '请先打开或开始本地任务。'
        return
    }

    try {
        $pausePath = Join-Path $script:CurrentJobDirectory 'pause.flag'
        $stopPath = Join-Path $script:CurrentJobDirectory 'stop.flag'
        $progressPath = Join-Path $script:CurrentJobDirectory 'progress.json'
        $state = if (Test-Path -LiteralPath $progressPath) { Read-LocalJson -Path $progressPath } else { $null }
        if ($null -ne $state -and
            (($state.State -in @('Recovered', 'NotEncrypted')) -or
             ($state.State -eq 'Exhausted' -and (Test-IsFinalCumulativeExhausted -Progress $state)))) {
            Show-UiError ('此本地任务已结束：' + (Convert-StateName -Value ([string]$state.State)))
            return
        }

        $activity = Get-CurrentJobRuntimeActivity
        if (-not $activity.Known) {
            throw ('无法确认当前 Job 是否已经停止：' + [string]$activity.Reason)
        }
        if ($activity.Active) {
            $hasStopFlag = Test-Path -LiteralPath $stopPath -PathType Leaf
            $canReleaseCpuPause = $null -ne $state -and [string]$state.State -eq 'Paused' -and
                -not $hasStopFlag -and (Test-Path -LiteralPath $pausePath -PathType Leaf) -and
                @($activity.WorkerProcessIds).Count -gt 0 -and @($activity.HashcatProcessIds).Count -eq 0
            if ($canReleaseCpuPause) {
                Remove-Item -LiteralPath $pausePath -Force
                Write-UiLog '已继续仍在后台等待的本地 CPU Worker。'
            }
            else {
                throw '当前 Job 仍有 Worker 或 Hashcat 正在运行/停止，请等待其退出后再继续。'
            }
            return
        }

        # A stopped GPU Worker may leave pause.flag and stop.flag together.
        # Confirm quiescence again before removing either control flag; restore
        # and coverage checkpoint files are deliberately untouched.
        $activity = Wait-CurrentJobRuntimeInactive -TimeoutSeconds 5
        if (-not $activity.Known) {
            throw ('无法确认当前 Job 已退出：' + [string]$activity.Reason)
        }
        if ($activity.Active) {
            throw '旧 Worker 尚未完全退出，请稍后再继续。'
        }
        $resumePreparation = Prepare-RecoveryJobResume -JobDirectory $script:CurrentJobDirectory -RuntimeRoot $runtimeRoot
        Reset-LiveTaskDisplay
        Start-WorkerProcess -ResumeJob
        Write-UiLog '已从保存的本地断点重新启动 Worker。'
    }
    catch {
        Show-UiError $_.Exception.Message
    }
}

function Stop-CurrentJob {
    if ([string]::IsNullOrWhiteSpace($script:CurrentJobDirectory)) {
        Show-UiError '没有可停止的本地任务。'
        return
    }

    $activity = Get-CurrentJobRuntimeActivity
    if (-not $activity.Known) {
        Show-UiError ('无法确认当前 Worker 状态：' + [string]$activity.Reason)
        return
    }
    if (-not $activity.Active) {
        Show-UiError '当前 Worker 已退出，任务已中断；现有断点仍可点击“继续”。'
        Update-TaskControls -State 'Interrupted'
        return
    }
    [System.IO.File]::WriteAllText((Join-Path $script:CurrentJobDirectory 'stop.flag'), 'stop')
    Write-UiLog '已请求停止。Worker 会在当前本地候选测试完成后写入断点。'
}

function Reset-CurrentArchiveInitialization {
    try {
        $activity = Get-CurrentJobRuntimeActivity
        if (-not $activity.Known) {
            throw ('无法确认当前任务是否仍在运行，已停止恢复初始化：' + [string]$activity.Reason)
        }
        if ($activity.Active) {
            throw '当前任务仍在运行，请先暂停或停止后再恢复初始化。'
        }
        $archivePath = [string]$controls.ArchivePathBox.Text
        if ([string]::IsNullOrWhiteSpace($archivePath) -or -not (Test-Path -LiteralPath $archivePath -PathType Leaf)) {
            throw '请先选择一个仍存在的本地压缩包。'
        }

        $firstConfirmation = [System.Windows.MessageBox]::Show(
            $window,
            '将清除当前压缩包由本工具保存的任务进度、断点、临时运行数据和测试状态。原压缩包、用户字典、资源与其他任务不会删除。是否继续？',
            '确认恢复初始化',
            [System.Windows.MessageBoxButton]::YesNo,
            [System.Windows.MessageBoxImage]::Warning
        )
        if ($firstConfirmation -ne [System.Windows.MessageBoxResult]::Yes) { return }

        $secondConfirmation = [System.Windows.MessageBox]::Show(
            $window,
            '请再次确认：只清理与当前压缩包身份匹配的本地任务数据，操作完成后可重新开始恢复，但已保存的进度不能恢复。',
            '再次确认恢复初始化',
            [System.Windows.MessageBoxButton]::YesNo,
            [System.Windows.MessageBoxImage]::Warning
        )
        if ($secondConfirmation -ne [System.Windows.MessageBoxResult]::Yes) { return }

        $result = Reset-RecoveryJobData -JobsRoot $jobsRoot -RuntimeRoot $runtimeRoot -ArchivePath $archivePath -CurrentJobDirectory ([string]$script:CurrentJobDirectory)
        $script:CurrentJobDirectory = $null
        $script:CurrentJobId = ''
        $script:CurrentWorker = $null
        Reset-LiveTaskDisplay
        $controls.StateValue.Text = '空闲'
        $controls.ProgressPercentValue.Text = '当前没有本地任务正在运行。'
        $controls.ProgressMessageText.Text = '当前压缩包的本地恢复状态已清除，可以重新开始。'
        Update-TaskControls -State ''
        Write-UiLog ('已完成当前压缩包的恢复初始化，清理 {0} 个本地任务；原压缩包和用户字典未删除。' -f $result.RemovedJobCount)
    }
    catch {
        Show-UiError $_.Exception.Message
    }
}

function Clear-PerformanceEstimateCache {
    try {
        $confirmation = [System.Windows.MessageBox]::Show(
            $window,
            '只清理本工具的本地性能估算缓存；任务进度、压缩包、用户字典和其他加速缓存不会删除。是否继续？',
            '确认清理性能估算缓存',
            [System.Windows.MessageBoxButton]::YesNo,
            [System.Windows.MessageBoxImage]::Warning
        )
        if ($confirmation -ne [System.Windows.MessageBoxResult]::Yes) { return }
        $removedCount = Clear-PerformanceProfiles
        Write-UiLog ('已清理性能估算缓存（{0} 个缓存项）。首次运行将重新校准 ETA。' -f $removedCount)
    }
    catch {
        Show-UiError $_.Exception.Message
    }
}

function Open-SavedJob {
    $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
    $dialog.Description = '选择包含 job.json 的本地压缩包密码恢复任务目录'
    $dialog.SelectedPath = $jobsRoot
    if ($dialog.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) { return }

    try {
        $jobPath = Join-Path $dialog.SelectedPath 'job.json'
        if (-not (Test-Path -LiteralPath $jobPath -PathType Leaf)) {
            throw '所选目录不包含 job.json。'
        }
        $job = Read-LocalJson -Path $jobPath
        if ($job.PSObject.Properties.Name -notcontains 'ArchiveIdentity' -or $null -eq $job.ArchiveIdentity) {
            throw '保存的任务缺少归档身份，无法安全继续。请创建新任务。'
        }
        $savedIdentity = Get-ArchiveIdentity -Path ([string]$job.ArchivePath)
        if (-not (Test-ArchiveIdentityMatch -Expected $job.ArchiveIdentity -Actual $savedIdentity)) {
            throw '压缩包自任务创建后已发生变化，无法继续使用原有恢复进度。请创建新任务。'
        }
        $script:CurrentJobDirectory = $dialog.SelectedPath
        $script:CurrentJobId = if ($job.PSObject.Properties.Name -contains 'JobId' -and -not [string]::IsNullOrWhiteSpace([string]$job.JobId)) {
            [string]$job.JobId
        }
        else {
            [System.IO.Path]::GetFileName(([System.IO.Path]::GetFullPath($script:CurrentJobDirectory)).TrimEnd('\'))
        }
        Reset-UiElapsedState
        $controls.ArchivePathBox.Text = [string]$job.ArchivePath
        $script:CurrentInspection = $null
        Set-ArchiveDisplayState -HasValidArchive:$false
        Update-TaskControls
        $savedLevel = if ($job.PSObject.Properties.Name -contains 'RecoveryLevel') {
            [string]$job.RecoveryLevel
        }
        else {
            switch ([string]$job.Strategy) {
                'Quick' { '1' }
                'Dictionary' { '2' }
                'Rules' { '3' }
                'Mask' { '4' }
                'BruteForce' { '5' }
                default { '' }
            }
        }
        if (-not (Set-SelectedValue -Control $controls.StrategyBox -Value $savedLevel)) {
            throw '保存的任务没有有效的恢复级别。'
        }
        [void](Ensure-DeviceChoicesReady)
        Restore-SavedDeviceChoice -Job $job
        $controls.QuickCandidatesBox.Text = (@($job.QuickCandidates) -join [Environment]::NewLine)
        $controls.TryEmptyPasswordBox.IsChecked = [bool]$job.TryEmptyPassword
        $controls.DictionaryPathBox.Text = [string]$job.DictionaryPath
        $controls.MaskBox.Text = [string]$job.Mask
        [void](Set-SelectedValue -Control $controls.CharacterSetBox -Value ([string]$job.CharacterSet))
        $controls.CustomCharacterSetBox.Text = [string]$job.CustomCharacters
        $controls.MinLengthBox.Text = [string]$job.MinLength
        $controls.MaxLengthBox.Text = [string]$job.MaxLength
        $controls.ArchiveFileNameText.Text = [System.IO.Path]::GetFileName([string]$job.ArchivePath)
        Update-StrategyHelp
        try { $null = Inspect-SelectedArchive } catch { Clear-SelectedArchive; Write-UiLog ('已打开保存的任务；检查将稍后进行：' + (Convert-UiMessage -Message $_.Exception.Message)) }
        Update-TaskControls
        Write-UiLog '已打开保存的本地任务。若 Worker 已停止，请点击“继续”。'
    }
    catch {
        Show-UiError $_.Exception.Message
    }
}

function Update-ProgressFromDisk {
    if ([string]::IsNullOrWhiteSpace($script:CurrentJobDirectory)) { return }
    $progressPath = Join-Path $script:CurrentJobDirectory 'progress.json'
    if (-not (Test-Path -LiteralPath $progressPath -PathType Leaf)) {
        Update-UiElapsedFromProgress
        return
    }

    try {
        $progress = Read-LocalJson -Path $progressPath
        $script:LastProgressSnapshot = $progress
        $persistedState = [string]$progress.State
        $runtimeActivity = Get-CurrentJobRuntimeActivity
        $displayState = $persistedState
        $staleRunning = $persistedState -in @('Starting', 'Running', 'Pausing', 'Stopping') -and
            $runtimeActivity.Known -and -not $runtimeActivity.Active
        if ($staleRunning) {
            $displayState = 'Interrupted'
        }
        elseif ($displayState -eq 'Exhausted' -and -not (Test-IsFinalCumulativeExhausted -Progress $progress) -and
            $runtimeActivity.Known -and $runtimeActivity.Active) {
            $displayState = 'Running'
        }
        Update-UiElapsedFromProgress -Progress $progress -DisplayState $displayState
        $controls.StateValue.Text = Convert-StateName -Value $displayState
        $stageText = if ($progress.PSObject.Properties.Name -contains 'StageNumber' -and $progress.StageNumber -gt 0) {
            $displayName = if ($progress.PSObject.Properties.Name -contains 'StageName' -and -not [string]::IsNullOrWhiteSpace([string]$progress.StageName)) {
                Convert-StrategyName -Value ([string]$progress.StageName)
            }
            else {
                Convert-StrategyName -Value ([string]$progress.Strategy)
            }
            ('{0}（{1}/{2}）' -f $displayName, $progress.StageNumber, $progress.StageCount)
        }
        else {
            Convert-StrategyName -Value ([string]$progress.Strategy)
        }
        $backendText = if ($progress.PSObject.Properties.Name -contains 'Backend') { Convert-BackendName -Value ([string]$progress.Backend) } else { Convert-BackendName -Value ([string]$progress.Engine) }
        $activity = if ($staleRunning) { 'Interrupted' } elseif ($progress.PSObject.Properties.Name -contains 'Activity' -and -not [string]::IsNullOrWhiteSpace([string]$progress.Activity)) { [string]$progress.Activity } else { $displayState }
        $activityMessage = if ($staleRunning) {
            '任务已中断，未发现对应 Worker 或 Hashcat；当前断点和恢复状态已保留，请点击“继续”。'
        }
        elseif ($progress.PSObject.Properties.Name -contains 'ActivityMessage' -and -not [string]::IsNullOrWhiteSpace([string]$progress.ActivityMessage)) {
            [string]$progress.ActivityMessage
        }
        else {
            [string]$progress.Message
        }
        $currentCoverageName = if ($progress.PSObject.Properties.Name -contains 'CurrentCoverageName' -and -not [string]::IsNullOrWhiteSpace([string]$progress.CurrentCoverageName)) { [string]$progress.CurrentCoverageName } else { '' }
        $preparationCurrent = if ($progress.PSObject.Properties.Name -contains 'PreparationCurrent') { $progress.PreparationCurrent } else { $null }
        $preparationTotal = if ($progress.PSObject.Properties.Name -contains 'PreparationTotal') { $progress.PreparationTotal } else { $null }
        $preparationUnit = if ($progress.PSObject.Properties.Name -contains 'PreparationUnit') { [string]$progress.PreparationUnit } else { '' }
        $johnCursorReliable = if ($progress.PSObject.Properties.Name -contains 'JohnCandidateProgressReliable') { [bool]$progress.JohnCandidateProgressReliable } else { $true }
        $overallStageName = if ($progress.PSObject.Properties.Name -contains 'OverallStageDisplayName' -and -not [string]::IsNullOrWhiteSpace([string]$progress.OverallStageDisplayName)) { [string]$progress.OverallStageDisplayName } elseif ($progress.PSObject.Properties.Name -contains 'StageName') { [string]$progress.StageName } else { '' }
        if ([string]::IsNullOrWhiteSpace($overallStageName) -and $progress.PSObject.Properties.Name -contains 'Strategy') { $overallStageName = [string]$progress.Strategy }
        [int]$overallStageNumber = 0
        [int]$overallStageCount = 0
        try { if ($progress.PSObject.Properties.Name -contains 'OverallStageNumber' -and $null -ne $progress.OverallStageNumber) { $overallStageNumber = [int]$progress.OverallStageNumber } elseif ($progress.PSObject.Properties.Name -contains 'StageNumber' -and $null -ne $progress.StageNumber) { $overallStageNumber = [int]$progress.StageNumber } } catch { $overallStageNumber = 0 }
        try { if ($progress.PSObject.Properties.Name -contains 'OverallStageCount' -and $null -ne $progress.OverallStageCount) { $overallStageCount = [int]$progress.OverallStageCount } elseif ($progress.PSObject.Properties.Name -contains 'StageCount' -and $null -ne $progress.StageCount) { $overallStageCount = [int]$progress.StageCount } } catch { $overallStageCount = 0 }
        [long]$overallPlanCount = 0
        [long]$overallProcessedCount = 0
        [double]$overallPercent = 0
        $overallOrdinal = $null
        try { if ($progress.PSObject.Properties.Name -contains 'OverallCoverageTotal' -and $null -ne $progress.OverallCoverageTotal) { $overallPlanCount = [long]$progress.OverallCoverageTotal } elseif ($progress.PSObject.Properties.Name -contains 'PlanCoverageCount' -and $null -ne $progress.PlanCoverageCount) { $overallPlanCount = [long]$progress.PlanCoverageCount } } catch { $overallPlanCount = 0 }
        try { if ($progress.PSObject.Properties.Name -contains 'OverallCoverageCompleted' -and $null -ne $progress.OverallCoverageCompleted) { $overallProcessedCount = [long]$progress.OverallCoverageCompleted } elseif ($progress.PSObject.Properties.Name -contains 'ProcessedCoverageCount' -and $null -ne $progress.ProcessedCoverageCount) { $overallProcessedCount = [long]$progress.ProcessedCoverageCount } } catch { $overallProcessedCount = 0 }
        try { if ($progress.PSObject.Properties.Name -contains 'OverallProgressPercent' -and $null -ne $progress.OverallProgressPercent) { $overallPercent = [double]$progress.OverallProgressPercent } elseif ($progress.PSObject.Properties.Name -contains 'OverallFlowPercent' -and $null -ne $progress.OverallFlowPercent) { $overallPercent = [double]$progress.OverallFlowPercent } } catch { $overallPercent = 0 }
        try { if ($progress.PSObject.Properties.Name -contains 'CurrentCoverageOrdinal' -and $null -ne $progress.CurrentCoverageOrdinal) { $overallOrdinal = [int]$progress.CurrentCoverageOrdinal } } catch { $overallOrdinal = $null }

        $overallCandidatesTested = if ($progress.PSObject.Properties.Name -contains 'OverallCandidatesTested') { $progress.OverallCandidatesTested } elseif ($progress.PSObject.Properties.Name -contains 'CandidatesTested') { $progress.CandidatesTested } else { $null }
        $overallCandidatesTotal = if ($progress.PSObject.Properties.Name -contains 'OverallCandidatesTotal') { $progress.OverallCandidatesTotal } else { $null }
        $overallCandidatesKnownTotal = if ($progress.PSObject.Properties.Name -contains 'OverallCandidatesKnownTotal') { $progress.OverallCandidatesKnownTotal } else { $null }
        $overallCandidatesRemaining = if ($progress.PSObject.Properties.Name -contains 'OverallCandidatesRemaining') { $progress.OverallCandidatesRemaining } else { $null }
        $overallCandidatesPartial = $progress.PSObject.Properties.Name -contains 'OverallCandidatesTotalIsPartial' -and [bool]$progress.OverallCandidatesTotalIsPartial
        $overallTotalReadiness = if ($progress.PSObject.Properties.Name -contains 'OverallTotalReadiness' -and -not [string]::IsNullOrWhiteSpace([string]$progress.OverallTotalReadiness)) {
            [string]$progress.OverallTotalReadiness
        }
        elseif ($null -ne $overallCandidatesTotal) {
            'Exact'
        }
        elseif ($overallCandidatesPartial) {
            'Partial'
        }
        else {
            'Unavailable'
        }
        if ($overallTotalReadiness -eq 'Partial') { $overallCandidatesPartial = $true }
        $overallSpeed = if ($progress.PSObject.Properties.Name -contains 'OverallSpeed') { $progress.OverallSpeed } elseif ($progress.PSObject.Properties.Name -contains 'SpeedPerSecond') { $progress.SpeedPerSecond } else { $null }
        $overallEta = if ($progress.PSObject.Properties.Name -contains 'DisplayedPlanEtaSeconds') { $progress.DisplayedPlanEtaSeconds } elseif ($progress.PSObject.Properties.Name -contains 'OverallEtaSeconds') { $progress.OverallEtaSeconds } else { $null }
        $overallEtaLow = if ($progress.PSObject.Properties.Name -contains 'DisplayedPlanEtaLowSeconds' -and $null -ne $progress.DisplayedPlanEtaLowSeconds) {
            $progress.DisplayedPlanEtaLowSeconds
        }
        elseif ($progress.PSObject.Properties.Name -contains 'PlanEtaLowSeconds') {
            $progress.PlanEtaLowSeconds
        }
        else { $null }
        $overallEtaHigh = if ($progress.PSObject.Properties.Name -contains 'DisplayedPlanEtaHighSeconds' -and $null -ne $progress.DisplayedPlanEtaHighSeconds) {
            $progress.DisplayedPlanEtaHighSeconds
        }
        elseif ($progress.PSObject.Properties.Name -contains 'PlanEtaHighSeconds') {
            $progress.PlanEtaHighSeconds
        }
        else { $null }
        $overallEtaReadiness = if ($progress.PSObject.Properties.Name -contains 'EtaReadiness' -and
            [string]$progress.EtaReadiness -in @('Calibrating', 'Preliminary', 'Stable')) {
            [string]$progress.EtaReadiness
        }
        elseif ($progress.PSObject.Properties.Name -contains 'OverallEtaReadiness' -and
            [string]$progress.OverallEtaReadiness -in @('Calibrating', 'Preliminary', 'Stable')) {
            [string]$progress.OverallEtaReadiness
        }
        else { 'Unavailable' }
        $overallEtaHasValidHistory = $progress.PSObject.Properties.Name -contains 'OverallEtaHasValidHistory' -and [bool]$progress.OverallEtaHasValidHistory
        $overallEtaIsHeld = $progress.PSObject.Properties.Name -contains 'OverallEtaIsHeld' -and [bool]$progress.OverallEtaIsHeld
        $overallEtaKnownLowerBound = if ($progress.PSObject.Properties.Name -contains 'PlanEtaKnownLowerBoundSeconds') { $progress.PlanEtaKnownLowerBoundSeconds } else { $null }
        [int]$requiredSpeedClassCount = 0
        [int]$calibratedRequiredSpeedClassCount = 0
        try {
            if ($progress.PSObject.Properties.Name -contains 'RequiredFutureSpeedClassCount' -and $null -ne $progress.RequiredFutureSpeedClassCount) {
                $requiredSpeedClassCount = [int]$progress.RequiredFutureSpeedClassCount
            }
            elseif ($progress.PSObject.Properties.Name -contains 'RequiredSpeedClassCount' -and $null -ne $progress.RequiredSpeedClassCount) {
                $requiredSpeedClassCount = [int]$progress.RequiredSpeedClassCount
            }
            if ($progress.PSObject.Properties.Name -contains 'CalibratedRequiredSpeedClassCount' -and $null -ne $progress.CalibratedRequiredSpeedClassCount) {
                $calibratedRequiredSpeedClassCount = [int]$progress.CalibratedRequiredSpeedClassCount
            }
        }
        catch {
            $requiredSpeedClassCount = 0
            $calibratedRequiredSpeedClassCount = 0
        }
        $etaCalibrationCoverage = if ($progress.PSObject.Properties.Name -contains 'EtaCalibrationCoverage') { $progress.EtaCalibrationCoverage } else { $null }
        [int]$unestimatedCoverageCount = 0
        try { if ($progress.PSObject.Properties.Name -contains 'UnestimatedCoverageCount' -and $null -ne $progress.UnestimatedCoverageCount) { $unestimatedCoverageCount = [int]$progress.UnestimatedCoverageCount } } catch { $unestimatedCoverageCount = 0 }
        $planEtaAdjustmentReason = if ($progress.PSObject.Properties.Name -contains 'PlanEtaAdjustmentReason') { [string]$progress.PlanEtaAdjustmentReason } else { '' }
        $overallSpeedIsRecent = $progress.PSObject.Properties.Name -contains 'OverallSpeedIsRecent' -and [bool]$progress.OverallSpeedIsRecent
        $overallInvariantViolation = $progress.PSObject.Properties.Name -contains 'ProgressInvariantViolation' -and [bool]$progress.ProgressInvariantViolation

        $overallStageText = '等待开始'
        if ($overallStageNumber -gt 0 -and -not [string]::IsNullOrWhiteSpace($overallStageName)) {
            $overallStageText = if ($overallStageCount -gt 0) {
                '{0}（{1}/{2}）' -f (Convert-StrategyName -Value $overallStageName), $overallStageNumber, $overallStageCount
            }
            else {
                Convert-StrategyName -Value $overallStageName
            }
        }
        $overallCoverageText = if (-not [string]::IsNullOrWhiteSpace($currentCoverageName)) {
            $currentCoverageName
        }
        elseif ($null -ne $overallOrdinal -and $overallOrdinal -gt 0) {
            '第 {0} 个搜索范围' -f $overallOrdinal
        }
        elseif ($displayState -eq 'Recovered') {
            '密码已恢复，后续搜索已停止'
        }
        elseif ($displayState -eq 'Exhausted') {
            '所有搜索范围已完成'
        }
        else {
            '正在准备搜索范围'
        }

        if (-not $johnCursorReliable) {
            # The overall plan can still know its shape, but it cannot turn a
            # John bulk speed sample into a truthful current-plan cursor.
            $overallPlanCount = 0
            $overallProcessedCount = 0
            $overallPercent = 0
            $overallCandidatesTested = $null
            $overallCandidatesRemaining = $null
            $overallEta = $null
            $overallEtaLow = $null
            $overallEtaHigh = $null
            $overallEtaReadiness = 'Unavailable'
        }

        if ($overallPlanCount -gt 0) {
            if ($overallProcessedCount -lt 0) { $overallProcessedCount = 0 }
            if ($overallProcessedCount -gt $overallPlanCount) { $overallProcessedCount = $overallPlanCount }
            if ($overallPercent -lt 0) { $overallPercent = 0 }
            if ($overallPercent -gt 100) { $overallPercent = 100 }
            $controls.OverallProgressBar.IsIndeterminate = $false
            $controls.OverallProgressBar.Foreground = New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.Color]::FromRgb(47, 117, 201))
            $controls.OverallProgressBar.Value = $overallPercent
            $controls.OverallProgressPercent.Text = '{0:N2}%' -f $overallPercent
            $controls.OverallProgressSummary.Text = '{0} / {1}' -f (Format-LocalCount -Value $overallProcessedCount), (Format-LocalCount -Value $overallPlanCount)
        }
        else {
            $controls.OverallProgressBar.IsIndeterminate = $false
            $controls.OverallProgressBar.Value = 0
            $controls.OverallProgressBar.Foreground = New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.Color]::FromRgb(170, 178, 188))
            $controls.OverallProgressPercent.Text = '—'
            $controls.OverallProgressSummary.Text = '准备后显示'
        }

        $controls.OverallCandidatesTestedLabel.Text = '已累计测试'
        $controls.OverallCandidatesRemainingLabel.Text = if ($overallTotalReadiness -eq 'Partial') { '剩余待尝试（基于已知范围）' } else { '剩余待尝试' }
        if ($null -ne $overallCandidatesTested) {
            if ($overallTotalReadiness -eq 'Exact' -and $null -ne $overallCandidatesTotal) {
                $controls.OverallCandidatesTestedValue.Text = '{0} / {1}' -f (Format-LocalCount -Value $overallCandidatesTested), (Format-LocalCount -Value $overallCandidatesTotal)
            }
            elseif ($overallTotalReadiness -eq 'Partial' -and $null -ne $overallCandidatesKnownTotal -and [long]$overallCandidatesKnownTotal -gt 0) {
                $controls.OverallCandidatesTestedValue.Text = '{0} / 已知 {1}' -f (Format-LocalCount -Value $overallCandidatesTested), (Format-LocalCount -Value $overallCandidatesKnownTotal)
            }
            else {
                $controls.OverallCandidatesTestedValue.Text = Format-LocalCount -Value $overallCandidatesTested
            }
        }
        else {
            $controls.OverallCandidatesTestedValue.Text = '等待采样'
        }
        if ($null -ne $overallCandidatesRemaining) {
            $controls.OverallCandidatesRemainingValue.Text = Format-LocalCount -Value $overallCandidatesRemaining
        }
        elseif ($overallTotalReadiness -eq 'Partial') {
            $controls.OverallCandidatesRemainingValue.Text = '暂无已知范围'
        }
        else {
            $controls.OverallCandidatesRemainingValue.Text = '准备后显示'
        }

        [double]$overallSpeedNumber = 0
        try { if ($null -ne $overallSpeed) { $overallSpeedNumber = [double]$overallSpeed } } catch { $overallSpeedNumber = 0 }
        if ($overallSpeedNumber -gt 0) {
            $controls.OverallSpeedValue.Text = (Format-LocalRate -Value $overallSpeedNumber) + ' 候选/秒'
        }
        else {
            $controls.OverallSpeedValue.Text = '开始搜索后显示'
        }

        $controls.OverallEtaValue.Text = Get-OverallEtaPrimaryText -DisplayState $displayState -Readiness $overallEtaReadiness -EtaSeconds $overallEta -EtaLowSeconds $overallEtaLow -EtaHighSeconds $overallEtaHigh -InvariantViolation:$overallInvariantViolation -Activity $activity -HasValidHistory:$overallEtaHasValidHistory

        $overallHelperText = ''
        if ($activity -in @('Pausing', 'Paused', 'Stopping', 'Stopped') -or $displayState -in @('Recovered', 'Exhausted')) {
            # Keep the coarse primary state message authoritative while the
            # task is paused/stopped or already terminal.
        }
        elseif ($overallEtaReadiness -eq 'Calibrating') {
            $calibrationParts = New-Object 'System.Collections.Generic.List[string]'
            if ($planEtaAdjustmentReason -eq 'StructuralRecalibration') {
                [void]$calibrationParts.Add('计算设备或恢复计划已变化，正在重新校准预计时间')
            }
            else {
                [void]$calibrationParts.Add('正在根据实际 CPU/GPU 搜索速度校准预计时间')
            }
            if ($requiredSpeedClassCount -gt 0) {
                [void]$calibrationParts.Add(('已校准 {0} / {1} 类搜索速度' -f $calibratedRequiredSpeedClassCount, $requiredSpeedClassCount))
            }
            if ($null -ne $overallEtaKnownLowerBound) {
                try {
                    if ([double]$overallEtaKnownLowerBound -gt 0) {
                        [void]$calibrationParts.Add(('已确认的搜索范围至少还需{0}，其余范围仍在校准' -f (Format-LocalDuration -Seconds $overallEtaKnownLowerBound)))
                    }
                }
                catch { }
            }
            $overallHelperText = $calibrationParts -join '；'
        }
        elseif ($overallEtaIsHeld -and $null -ne $overallEta -and -not $overallInvariantViolation) {
            $overallHelperText = '正在准备下一搜索范围，预计时间按最近有效速度保持并将在搜索开始后校正'
        }
        elseif ($planEtaAdjustmentReason -eq 'StructuralRecalibration') {
            $overallHelperText = '已根据当前搜索范围重新校正预计时间'
        }
        elseif ($overallEtaReadiness -eq 'Preliminary') {
            $overallHelperText = '初步预计；按当前已校准速度和未完成范围的保守区间估算'
            if ($requiredSpeedClassCount -gt $calibratedRequiredSpeedClassCount) {
                $overallHelperText += ('；仍有 {0} 类搜索速度正在校准，预计时间可能继续调整' -f ($requiredSpeedClassCount - $calibratedRequiredSpeedClassCount))
            }
        }
        elseif ($overallEtaReadiness -eq 'Stable') {
            $overallHelperText = '稳定预计；按当前恢复计划和已校准速度估算'
        }
        elseif ($overallEtaReadiness -eq 'Unavailable' -and -not $overallEtaHasValidHistory) {
            $overallHelperText = '整体搜索计划正在准备，完成后显示完整总量与预计完成时间'
        }
        elseif ($null -eq $overallEta -and $overallSpeedNumber -le 0 -and -not $overallEtaHasValidHistory -and $displayState -notin @('Recovered', 'Exhausted')) {
            $overallHelperText = '开始搜索后显示当前搜索速度与预计完成时间'
        }
        $controls.OverallProgressHelper.Text = $overallHelperText
        $controls.OverallProgressHelper.Visibility = if ([string]::IsNullOrWhiteSpace($overallHelperText)) { [System.Windows.Visibility]::Collapsed } else { [System.Windows.Visibility]::Visible }
        $controls.OverallStageValue.Text = $overallStageText
        $controls.OverallCoverageValue.Text = $overallCoverageText
        $overallStatusMessage = if ($progress.PSObject.Properties.Name -contains 'OverallStatusMessage') { [string]$progress.OverallStatusMessage } else { '' }
        $overallStatusText = switch ($activity) {
            { $_ -like 'Preparing*' } { '准备中'; break }
            'StartingHashcat' { '启动后端'; break }
            'RestoringHashcat' { '恢复断点'; break }
            'RunningCoverage' { '搜索中'; break }
            'VerifyingCandidate' { '验证候选'; break }
            'Pausing' { '暂停中'; break }
            'Paused' { '已暂停'; break }
            'Stopping' { '停止中'; break }
            'Stopped' { '已停止'; break }
            'Recovered' { '已恢复'; break }
            'Exhausted' { '已完成'; break }
            'Failed' { '已失败'; break }
            default { Convert-UiMessage -Message $overallStatusMessage }
        }
        if ([string]::IsNullOrWhiteSpace($overallStatusText)) {
            $overallStatusText = '准备中'
        }
        if ($activity -eq 'PreparingDictionary' -and $null -ne $preparationCurrent) {
            $overallStatusText = '准备中 · ' + (Format-PreparationProgress -Current $preparationCurrent -Total $preparationTotal -Unit $preparationUnit)
        }
        $controls.OverallProgressCurrent.Text = $overallStatusText
        $controls.StageValue.Text = $stageText
        $controls.CoverageValue.Text = if (-not [string]::IsNullOrWhiteSpace($currentCoverageName)) { $currentCoverageName } elseif ($activity -eq 'AdvancingCoverage') { '正在切换到下一个搜索范围' } else { '等待当前范围' }
        $controls.EngineValue.Text = $backendText
        $controls.DeviceValue.Text = if ($progress.PSObject.Properties.Name -contains 'ComputeDevice') { Convert-ComputeDeviceName -Value ([string]$progress.ComputeDevice) } else { 'CPU' }
        $isPreparation = $activity -like 'Preparing*'
        $preparationCurrent = if ($progress.PSObject.Properties.Name -contains 'PreparationCurrent') { $progress.PreparationCurrent } else { $null }
        $preparationTotal = if ($progress.PSObject.Properties.Name -contains 'PreparationTotal') { $progress.PreparationTotal } else { $null }
        $preparationUnit = if ($progress.PSObject.Properties.Name -contains 'PreparationUnit') { [string]$progress.PreparationUnit } else { '' }
        $controls.ProgressMetricLabel.Text = if ($isPreparation) { '准备进度' } else { '已测试数量' }
        $controls.SpeedLabel.Text = if ($isPreparation) { '准备速度' } else { '速度（平滑）' }
        $controls.ProgressBarLabel.Text = if ($isPreparation) { '准备进度' } else { '搜索进度' }

        [double]$preparationSpeed = 0
        try { if ($progress.PSObject.Properties.Name -contains 'PreparationSpeed' -and $null -ne $progress.PreparationSpeed) { $preparationSpeed = [double]$progress.PreparationSpeed } } catch { $preparationSpeed = 0 }
        if ($isPreparation) {
            $controls.CandidatesValue.Text = Format-PreparationProgress -Current $preparationCurrent -Total $preparationTotal -Unit $preparationUnit
            if ($preparationSpeed -gt 0) {
                $controls.SpeedValue.Text = if ($preparationUnit -eq 'Bytes') { ('{0}/秒' -f (Format-LocalBytes -Value $preparationSpeed)) } else { ('{0:N2} 词条/秒' -f $preparationSpeed) }
            }
            else { $controls.SpeedValue.Text = '正在采样准备速度…' }
        }
        else {
            $totalValue = if ($progress.PSObject.Properties.Name -contains 'CoverageTotal' -and $null -ne $progress.CoverageTotal) { $progress.CoverageTotal } elseif ($progress.PSObject.Properties.Name -contains 'CandidateTotal') { $progress.CandidateTotal } else { $null }
            $testedValue = if ($progress.PSObject.Properties.Name -contains 'CoverageTested' -and $null -ne $progress.CoverageTested) {
                $progress.CoverageTested
            }
            elseif ($progress.PSObject.Properties.Name -contains 'StageCandidatesTested' -and $null -ne $progress.StageCandidatesTested) {
                $progress.StageCandidatesTested
            }
            elseif ($progress.PSObject.Properties.Name -contains 'CandidatesTested' -and $null -ne $progress.CandidatesTested) {
                $progress.CandidatesTested
            }
            else { 0L }
            if (-not $johnCursorReliable) {
                $controls.CandidatesValue.Text = 'John 批量搜索中；已测试数量将在完成后报告'
            }
            elseif ($null -eq $totalValue) {
                $controls.CandidatesValue.Text = '已测试 {0} 个候选' -f (Format-LocalCount -Value $testedValue)
            }
            else {
                $controls.CandidatesValue.Text = '{0} / {1}' -f (Format-LocalCount -Value $testedValue), (Format-LocalCount -Value $totalValue)
            }
        }

        [double]$speed = 0
        try { if ($progress.PSObject.Properties.Name -contains 'SpeedPerSecond' -and $null -ne $progress.SpeedPerSecond) { $speed = [double]$progress.SpeedPerSecond } } catch { $speed = 0 }
        if (-not $isPreparation) {
            $controls.SpeedValue.Text = if ($speed -gt 0) { (Format-LocalRate -Value $speed) + ' 候选/秒' } elseif ($activity -in @('Paused', 'Pausing', 'Stopping', 'Stopped')) { '等待继续后的速度采样' } elseif ($activity -in @('StartingHashcat', 'RestoringHashcat')) { '搜索开始后显示' } else { '等待有效速度采样' }
        }
        $elapsedValue = if ($progress.PSObject.Properties.Name -contains 'ElapsedSeconds') { $progress.ElapsedSeconds } else { $null }
        $controls.ElapsedValue.Text = Format-LocalDuration -Seconds $elapsedValue

        $totalValue = if ($progress.PSObject.Properties.Name -contains 'CoverageTotal' -and $null -ne $progress.CoverageTotal) { $progress.CoverageTotal } elseif ($progress.PSObject.Properties.Name -contains 'CandidateTotal') { $progress.CandidateTotal } else { $null }
        $testedValue = if ($progress.PSObject.Properties.Name -contains 'CoverageTested' -and $null -ne $progress.CoverageTested) {
            $progress.CoverageTested
        }
        elseif ($progress.PSObject.Properties.Name -contains 'StageCandidatesTested' -and $null -ne $progress.StageCandidatesTested) {
            $progress.StageCandidatesTested
        }
        elseif ($progress.PSObject.Properties.Name -contains 'CandidatesTested' -and $null -ne $progress.CandidatesTested) {
            $progress.CandidatesTested
        }
        else { 0L }
        $total = Format-LocalCount -Value $totalValue
        $hasKnownTotal = ($johnCursorReliable -and $null -ne $totalValue -and [long]$totalValue -gt 0)
        $invariantViolation = ($progress.PSObject.Properties.Name -contains 'ProgressInvariantViolation' -and [bool]$progress.ProgressInvariantViolation)
        $hasProgress = (-not $invariantViolation -and $progress.PSObject.Properties.Name -contains 'ProgressPercent' -and $null -ne $progress.ProgressPercent)
        $preparationHasTotal = $null -ne $preparationTotal -and [long]$preparationTotal -gt 0
        $preparationHasProgress = $isPreparation -and $null -ne $preparationCurrent -and $preparationHasTotal -and [long]$preparationCurrent -le [long]$preparationTotal
        if ($preparationHasProgress) {
            [double]$preparationPercent = [math]::Round((100.0 * [long]$preparationCurrent) / [long]$preparationTotal, 2)
            $controls.SearchProgressBar.IsIndeterminate = $false
            $controls.SearchProgressBar.Value = $preparationPercent
            $controls.ProgressPercentValue.Text = '{0:N2}%（{1}）' -f $preparationPercent, (Format-PreparationProgress -Current $preparationCurrent -Total $preparationTotal -Unit $preparationUnit)
        }
        elseif ($isPreparation) {
            $controls.SearchProgressBar.IsIndeterminate = $true
            $controls.SearchProgressBar.Value = 0
            $controls.ProgressPercentValue.Text = if ($null -ne $preparationCurrent) { Format-PreparationProgress -Current $preparationCurrent -Total $preparationTotal -Unit $preparationUnit } else { Convert-UiMessage -Message $activityMessage }
        }
        elseif ($hasProgress) {
            [double]$percent = [double]$progress.ProgressPercent
            $controls.SearchProgressBar.IsIndeterminate = $false
            $controls.SearchProgressBar.Value = $percent
            $controls.ProgressPercentValue.Text = ('{0:N2}%（{1} / {2}）' -f $percent, (Format-LocalCount -Value $testedValue), $total)
        }
        else {
            $controls.SearchProgressBar.IsIndeterminate = $true
            $controls.SearchProgressBar.Value = 0
            $controls.ProgressPercentValue.Text = if ($invariantViolation) { '正在同步当前搜索进度…' } elseif (-not $johnCursorReliable) { 'John 批量搜索中；已测试数量和百分比将在完成后报告。' } elseif ($activity -ne 'RunningCoverage') { Convert-UiMessage -Message $activityMessage } elseif ($hasKnownTotal) { '正在根据当前本地速度估算进度…' } else { '当前搜索空间无法预先计算总量；总量将在执行过程中估算。' }
        }

        $estimated = if ($progress.PSObject.Properties.Name -contains 'EstimatedRemainingSeconds') { $progress.EstimatedRemainingSeconds } else { $null }
        $worstCase = if ($progress.PSObject.Properties.Name -contains 'WorstCaseRemainingSeconds') { $progress.WorstCaseRemainingSeconds } else { $null }
        $preparationEta = if ($progress.PSObject.Properties.Name -contains 'PreparationEtaSeconds') { $progress.PreparationEtaSeconds } else { $null }
        $etaAllowed = $johnCursorReliable -and -not $isPreparation -and $activity -eq 'RunningCoverage' -and $hasKnownTotal -and -not $invariantViolation -and [long]$testedValue -lt [long]$totalValue -and $speed -gt 0
        if ($isPreparation) {
            if ($null -ne $preparationEta -and [double]$preparationEta -gt 0) {
                $controls.EstimatedRemainingValue.Text = '准备' + (Format-LocalEta -Seconds $preparationEta)
            }
            elseif ($null -ne $preparationCurrent -and $preparationHasTotal -and [long]$preparationCurrent -ge [long]$preparationTotal) {
                $controls.EstimatedRemainingValue.Text = '准备已完成'
            }
            else {
                $controls.EstimatedRemainingValue.Text = '准备完成后更新'
            }
            $controls.WorstCaseValue.Text = '准备完成后更新'
        }
        elseif ($etaAllowed) {
            $controls.EstimatedRemainingValue.Text = Format-LocalEta -Seconds $estimated
            $controls.WorstCaseValue.Text = Format-LocalEta -Seconds $worstCase
        }
        elseif (-not $johnCursorReliable) {
            $controls.EstimatedRemainingValue.Text = 'John 批量搜索完成后更新'
            $controls.WorstCaseValue.Text = 'John 批量搜索完成后更新'
        }
        elseif ($invariantViolation) {
            $controls.EstimatedRemainingValue.Text = '正在同步当前搜索进度…'
            $controls.WorstCaseValue.Text = '正在同步当前搜索进度…'
        }
        elseif ($activity -in @('StartingHashcat', 'RestoringHashcat', 'Finalizing')) {
            $controls.EstimatedRemainingValue.Text = '当前范围准备中，完成后更新'
            $controls.WorstCaseValue.Text = '当前范围准备中，完成后更新'
        }
        elseif ($activity -eq 'VerifyingCandidate') {
            $controls.EstimatedRemainingValue.Text = '正在验证当前候选…'
            $controls.WorstCaseValue.Text = '正在验证当前候选…'
        }
        elseif ($activity -in @('Pausing', 'Paused', 'Stopping', 'Stopped')) {
            $controls.EstimatedRemainingValue.Text = '继续搜索后更新'
            $controls.WorstCaseValue.Text = '继续搜索后更新'
        }
        elseif ($hasKnownTotal -and [long]$testedValue -ge [long]$totalValue) {
            $controls.EstimatedRemainingValue.Text = '当前范围已处理完，正在切换'
            $controls.WorstCaseValue.Text = '当前范围已处理完，正在切换'
        }
        elseif (-not $hasKnownTotal) {
            $controls.EstimatedRemainingValue.Text = '当前范围总量确定后更新'
            $controls.WorstCaseValue.Text = '当前范围总量确定后更新'
        }
        elseif ($hasKnownTotal -and $speed -le 0) {
            $controls.EstimatedRemainingValue.Text = '获得速度采样后更新'
            $controls.WorstCaseValue.Text = '获得速度采样后更新'
        }
        else {
            $controls.EstimatedRemainingValue.Text = '当前范围暂无法可靠估算'
            $controls.WorstCaseValue.Text = '当前范围暂无法可靠估算'
        }
        $displayActivityMessage = Convert-UiMessage -Message $activityMessage
        if ($activity -like 'Preparing*' -or $activity -eq 'RunningCoverage') {
            $lastProgressUtc = $null
            if ($progress.PSObject.Properties.Name -contains 'LastProgressUtc' -and -not [string]::IsNullOrWhiteSpace([string]$progress.LastProgressUtc)) {
                try { $lastProgressUtc = [datetime]::Parse([string]$progress.LastProgressUtc, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind) } catch { $lastProgressUtc = $null }
            }
            if ($null -ne $lastProgressUtc) {
                $progressAge = ([datetime]::UtcNow - $lastProgressUtc.ToUniversalTime()).TotalSeconds
                if ($progressAge -gt 30) {
                    $displayActivityMessage += ' 当前步骤仍在处理中，暂未收到新的进度更新。'
                }
                elseif ($progressAge -gt 10) {
                    $displayActivityMessage += (' 正在处理当前本地任务，最近 {0:N0} 秒暂无新的进度采样…' -f $progressAge)
                }
            }
        }
        $controls.ProgressMessageText.Text = $displayActivityMessage

        $password = ''
        if ($null -ne $progress.Result -and $progress.Result.PSObject.Properties.Name -contains 'Password') {
            $password = [string]$progress.Result.Password
        }
        $controls.ResultValue.Text = $password
        $controls.ResultCard.Visibility = if ([string]::IsNullOrEmpty($password)) { [System.Windows.Visibility]::Collapsed } else { [System.Windows.Visibility]::Visible }
        if (-not [string]::IsNullOrEmpty($password)) {
            $controls.ResultStatusText.Text = '密码已恢复 · 已通过本机 NanaZip 验证'
        }
        Update-TaskControls -State $displayState

        if ($script:LastProgressUpdated -ne [string]$progress.UpdatedUtc) {
            $script:LastProgressUpdated = [string]$progress.UpdatedUtc
            if ($displayState -in @('Recovered', 'Exhausted', 'Stopped', 'Failed', 'BackendUnavailable', 'NotEncrypted')) {
                Write-UiLog ('本地任务状态：{0}。{1}' -f (Convert-StateName -Value $displayState), (Convert-UiMessage -Message ([string]$progress.Message)))
            }
        }
    }
    catch {
        # A worker replaces this JSON atomically; a short read race is harmless and will be retried by the timer.
        Update-UiElapsedFromProgress
    }
}

[void](Set-SelectedValue -Control $controls.StrategyBox -Value '1')

[void](Add-LocalizedComboChoice -Control $controls.CharacterSetBox -DisplayText '小写字母' -Value 'lower')
[void](Add-LocalizedComboChoice -Control $controls.CharacterSetBox -DisplayText '大写字母' -Value 'upper')
[void](Add-LocalizedComboChoice -Control $controls.CharacterSetBox -DisplayText '数字' -Value 'digits')
[void](Add-LocalizedComboChoice -Control $controls.CharacterSetBox -DisplayText '字母和数字' -Value 'alnum')
[void](Add-LocalizedComboChoice -Control $controls.CharacterSetBox -DisplayText '全部字符' -Value 'all')
[void](Add-LocalizedComboChoice -Control $controls.CharacterSetBox -DisplayText '自定义字符集' -Value 'custom')
[void](Set-SelectedValue -Control $controls.CharacterSetBox -Value 'alnum')

$controls.DeviceBox.Items.Clear()
[void](Add-LocalizedComboChoice -Control $controls.DeviceBox -DisplayText 'Auto（推荐）' -Value 'Auto')
[void](Add-LocalizedComboChoice -Control $controls.DeviceBox -DisplayText '仅使用 CPU' -Value 'CPU')
[void](Set-SelectedValue -Control $controls.DeviceBox -Value 'Auto')
$controls.DeviceInfoText.Text = '可用：Auto（推荐） · 仅使用 CPU · 正在检测本机 GPU…'
$controls.AdvancedDeviceInfoText.Text = '正在检测本机 GPU；窗口已就绪。'
Update-StrategyHelp
$controls.ArchiveFileNameText.Text = '尚未选择压缩包'
$controls.ArchiveInfoText.Text = '支持拖入单个本地 ZIP、7z、RAR 文件。'
$controls.ArchiveInfoText.ToolTip = $null
$controls.StateValue.Text = '空闲'
$controls.StageValue.Text = '等待开始'
$controls.CoverageValue.Text = '等待当前范围'
$controls.EngineValue.Text = '—'
$controls.DeviceValue.Text = '尚未开始'
$controls.ProgressMetricLabel.Text = '准备进度'
$controls.CandidatesValue.Text = '等待准备开始'
$controls.SpeedLabel.Text = '准备速度'
$controls.SpeedValue.Text = '暂无本地速度采样'
$controls.ElapsedValue.Text = '尚未开始'
$controls.EstimatedRemainingValue.Text = '准备阶段尚未开始'
$controls.WorstCaseValue.Text = '准备完成后估算'
$controls.ProgressBarLabel.Text = '准备进度'
$controls.SearchProgressBar.IsIndeterminate = $false
$controls.SearchProgressBar.Value = 0
$controls.ProgressPercentValue.Text = '当前没有本地任务正在运行。'
$controls.ProgressMessageText.Text = '当前没有本地任务正在运行。'
$controls.OverallProgressBar.IsIndeterminate = $false
$controls.OverallProgressBar.Value = 0
$controls.OverallProgressBar.Foreground = New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.Color]::FromRgb(170, 178, 188))
$controls.OverallProgressPercent.Text = '—'
$controls.OverallCandidatesTestedLabel.Text = '已累计测试'
$controls.OverallCandidatesTestedValue.Text = '等待开始'
$controls.OverallCandidatesRemainingLabel.Text = '剩余待尝试'
$controls.OverallCandidatesRemainingValue.Text = '准备后显示'
$controls.OverallSpeedValue.Text = '开始搜索后显示'
$controls.OverallEtaValue.Text = '开始搜索后显示'
$controls.OverallProgressSummary.Text = '准备后显示'
$controls.OverallStageValue.Text = '等待开始'
$controls.OverallCoverageValue.Text = '等待开始'
$controls.OverallProgressCurrent.Text = '等待开始'
$controls.OverallProgressHelper.Text = ''
$controls.OverallProgressHelper.Visibility = [System.Windows.Visibility]::Collapsed
$controls.ResultCard.Visibility = [System.Windows.Visibility]::Collapsed
Set-ArchiveDisplayState -HasValidArchive:$false
Update-TaskControls
Write-UiLog '已就绪。所有恢复计算均设计为仅在本机运行。'

$browseArchiveHandler = {
        $dialog = New-Object Microsoft.Win32.OpenFileDialog
        $dialog.Filter = '压缩包|*.zip;*.7z;*.rar;*.tar;*.gz;*.tgz;*.bz2;*.xz|所有文件|*.*'
        if ($dialog.ShowDialog()) {
            try { Select-ArchivePath -Path $dialog.FileName } catch { Show-UiError $_.Exception.Message }
        }
    }
$controls.BrowseArchiveButton.Add_Click($browseArchiveHandler)
$controls.ReplaceArchiveButton.Add_Click($browseArchiveHandler)
$controls.InspectButton.Add_Click({ try { $null = Inspect-SelectedArchive } catch { Show-UiError $_.Exception.Message } })
$controls.BrowseDictionaryButton.Add_Click({
        $dialog = New-Object Microsoft.Win32.OpenFileDialog
        $dialog.Filter = '文本字典|*.txt;*.lst;*.dic;*.wordlist|所有文件|*.*'
        if ($dialog.ShowDialog()) { $controls.DictionaryPathBox.Text = $dialog.FileName }
    })
$controls.StrategyBox.Add_SelectionChanged({ Update-StrategyHelp })
$controls.DeviceBox.Add_SelectionChanged({ Update-DeviceInfo })
$controls.StartButton.Add_Click({ Start-NewJob })
$controls.PauseButton.Add_Click({ Pause-CurrentJob })
$controls.ResumeButton.Add_Click({ Resume-CurrentJob })
$controls.StopButton.Add_Click({ Stop-CurrentJob })
$controls.OpenJobButton.Add_Click({ Open-SavedJob })
$controls.ResetCurrentArchiveButton.Add_Click({ Reset-CurrentArchiveInitialization })
$controls.ClearPerformanceProfilesButton.Add_Click({ Clear-PerformanceEstimateCache })

$dropZoneDragHandler = {
        param($sender, $eventArgs)
        if ($eventArgs.Data.GetDataPresent([System.Windows.DataFormats]::FileDrop)) {
            $eventArgs.Effects = [System.Windows.DragDropEffects]::Copy
            $controls.ArchiveDropZone.Background = New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.Color]::FromRgb(243, 248, 255))
            $controls.ArchiveDropZone.BorderBrush = New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.Color]::FromRgb(47, 117, 201))
        }
        else {
            $eventArgs.Effects = [System.Windows.DragDropEffects]::None
        }
        $eventArgs.Handled = $true
    }
$controls.ArchiveDropZone.Add_DragEnter($dropZoneDragHandler)
$controls.ArchiveDropZone.Add_DragOver($dropZoneDragHandler)
$controls.ArchiveDropZone.Add_DragLeave({
        $controls.ArchiveDropZone.Background = [System.Windows.Media.Brushes]::White
        $controls.ArchiveDropZone.BorderBrush = New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.Color]::FromRgb(175, 198, 224))
    })
$controls.ArchiveDropZone.Add_Drop({ param($sender, $eventArgs) Handle-ArchiveDrop -EventArgs $eventArgs })
$window.Add_DragOver({
        param($sender, $eventArgs)
        if ($eventArgs.Data.GetDataPresent([System.Windows.DataFormats]::FileDrop)) {
            $eventArgs.Effects = [System.Windows.DragDropEffects]::Copy
        }
        else {
            $eventArgs.Effects = [System.Windows.DragDropEffects]::None
        }
        $eventArgs.Handled = $true
    })
$window.Add_Drop({
        param($sender, $eventArgs)
        if (-not $eventArgs.Handled) { Handle-ArchiveDrop -EventArgs $eventArgs }
    })

$timer = New-Object System.Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromMilliseconds(500)
$timer.Add_Tick({ Update-ProgressFromDisk })
$timer.Start()

$window.Add_ContentRendered({
    if ($script:DeferredStartupScheduled) { return }
    $script:DeferredStartupScheduled = $true
    $deferredStartupAction = [System.Action]{ Invoke-DeferredStartup }
    $null = $window.Dispatcher.BeginInvoke([System.Windows.Threading.DispatcherPriority]::Background, $deferredStartupAction)
})

$window.Add_Closing({
        if (-not [string]::IsNullOrWhiteSpace($script:CurrentJobDirectory) -and (Get-WorkerIsRunning)) {
            [System.IO.File]::WriteAllText((Join-Path $script:CurrentJobDirectory 'pause.flag'), 'pause')
        }
        $timer.Stop()
    })

$null = $window.ShowDialog()

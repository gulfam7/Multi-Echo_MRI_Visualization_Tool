function MRI_Comparison_Tool_v5_3d()
% MRI_Comparison_Tool_v4 - Compare ground truth and motion-corrected MRI data
%
% New in v4:
%   - View Orientation dropdown: Axial (kx-ky), Coronal (kx-kz), Sagittal (ky-kz)
%   - Selecting a view auto-updates the slice slider range and jumps to midpoint
%   - extractSlice() helper centralises all dimension indexing
%   - Data assumed to be (kx, ky, kz, echoes)
%
% New in v3:
%   - Display Floor / Ceiling sliders for windowing (background artifact visibility)
%   - Auto-window button to reset, and presets for background enhancement
%
% Carried from v2:
%   1. Slider safe for num_slices==1 or num_echoes==1
%   2. Uses matfile() for v7.3 partial loading; falls back to load()
%   3. SSIM uses conv2 Gaussian kernel (no Image Processing Toolbox needed)
%   4. Phase difference computed as angle(GT .* conj(MC)) (wrapped)
%
% Usage: Run MRI_Comparison_Tool_v4() in MATLAB command window.

    %% ---- Create Main Figure ----
    fig = figure('Name', 'MRI Comparison Tool v4', ...
        'NumberTitle', 'off', ...
        'Units', 'normalized', ...
        'Position', [0.05 0.05 0.9 0.85], ...
        'Color', [0.15 0.15 0.15], ...
        'MenuBar', 'none', ...
        'ToolBar', 'figure', ...
        'CloseRequestFcn', @closeFig);

    %% ---- Application State ----
    state = struct();
    state.gt_data      = [];
    state.mc_data      = [];
    state.current_slice = 48;
    state.current_echo  = 1;
    state.num_slices    = 96;
    state.num_echoes    = 10;
    % NEW: orientation  1=Axial(kx-ky), 2=Coronal(kx-kz), 3=Sagittal(ky-kz)
    state.view_mode     = 1;
    state.display_mode  = 1;   % 1=Magnitude, 2=Phase, 3=Real, 4=Imaginary
    state.colormap_choice = 1;
    state.data_loaded   = false;
    state.link_clim     = false;
    state.norm_mode     = 1;   % 1=None, 2=Per-slice, 3=Global, 4=Percentile
    state.gt_name       = 'Ground Truth';
    state.mc_name       = 'Motion Corrected';
    % Windowing: floor/ceiling as fraction of [0, 1] after normalisation
    state.win_floor     = 0.0;
    state.win_ceiling   = 1.0;

    %% ---- UI: Top Panel (Load Buttons & Info) ----
    top_panel = uipanel(fig, 'Units', 'normalized', ...
        'Position', [0.01 0.92 0.98 0.07], ...
        'BackgroundColor', [0.2 0.2 0.2], ...
        'ForegroundColor', 'w', ...
        'Title', 'Data Loading', ...
        'FontSize', 10, 'FontWeight', 'bold');

    uicontrol(top_panel, 'Style', 'pushbutton', ...
        'String', 'Load Ground Truth', ...
        'Units', 'normalized', ...
        'Position', [0.01 0.15 0.15 0.7], ...
        'FontSize', 10, 'FontWeight', 'bold', ...
        'BackgroundColor', [0.3 0.6 0.3], ...
        'ForegroundColor', 'w', ...
        'Callback', @(~,~) loadData('gt'));

    state.gt_label = uicontrol(top_panel, 'Style', 'text', ...
        'String', 'No file loaded', ...
        'Units', 'normalized', ...
        'Position', [0.17 0.15 0.25 0.7], ...
        'FontSize', 9, ...
        'BackgroundColor', [0.2 0.2 0.2], ...
        'ForegroundColor', [0.8 0.8 0.8], ...
        'HorizontalAlignment', 'left');

    uicontrol(top_panel, 'Style', 'pushbutton', ...
        'String', 'Load Motion Corrected', ...
        'Units', 'normalized', ...
        'Position', [0.43 0.15 0.15 0.7], ...
        'FontSize', 10, 'FontWeight', 'bold', ...
        'BackgroundColor', [0.3 0.5 0.7], ...
        'ForegroundColor', 'w', ...
        'Callback', @(~,~) loadData('mc'));

    state.mc_label = uicontrol(top_panel, 'Style', 'text', ...
        'String', 'No file loaded', ...
        'Units', 'normalized', ...
        'Position', [0.59 0.15 0.25 0.7], ...
        'FontSize', 9, ...
        'BackgroundColor', [0.2 0.2 0.2], ...
        'ForegroundColor', [0.8 0.8 0.8], ...
        'HorizontalAlignment', 'left');

    uicontrol(top_panel, 'Style', 'pushbutton', ...
        'String', 'Load Demo Data', ...
        'Units', 'normalized', ...
        'Position', [0.86 0.15 0.13 0.7], ...
        'FontSize', 9, ...
        'BackgroundColor', [0.5 0.4 0.6], ...
        'ForegroundColor', 'w', ...
        'Callback', @(~,~) loadDemoData());

    %% ---- UI: Control Panel (Left Side) ----
    ctrl_panel = uipanel(fig, 'Units', 'normalized', ...
        'Position', [0.01 0.01 0.18 0.90], ...
        'BackgroundColor', [0.2 0.2 0.2], ...
        'ForegroundColor', 'w', ...
        'Title', 'Controls', ...
        'FontSize', 10, 'FontWeight', 'bold');

    % =================================================================
    % NEW: View Orientation (Axial / Coronal / Sagittal) — top of panel
    % =================================================================
    y_pos = 0.95;
    uicontrol(ctrl_panel, 'Style', 'text', ...
        'String', 'View Orientation', ...
        'Units', 'normalized', 'Position', [0.05 y_pos 0.9 0.03], ...
        'FontSize', 9, 'FontWeight', 'bold', ...
        'BackgroundColor', [0.2 0.2 0.2], 'ForegroundColor', [0.4 0.9 1.0]);

    y_pos = y_pos - 0.04;
    state.view_popup = uicontrol(ctrl_panel, 'Style', 'popupmenu', ...
        'String', {'Axial  (kx-ky | kz slices)', ...
                   'Coronal  (kx-kz | ky slices)', ...
                   'Sagittal  (ky-kz | kx slices)'}, ...
        'Units', 'normalized', 'Position', [0.05 y_pos 0.9 0.035], ...
        'FontSize', 9, 'Value', 1, ...
        'Callback', @viewChanged);

    % --- Slice Selection ---
    y_pos = y_pos - 0.05;
    uicontrol(ctrl_panel, 'Style', 'text', ...
        'String', 'Slice Selection', ...
        'Units', 'normalized', 'Position', [0.05 y_pos 0.9 0.03], ...
        'FontSize', 9, 'FontWeight', 'bold', ...
        'BackgroundColor', [0.2 0.2 0.2], 'ForegroundColor', [0.9 0.7 0.2]);

    y_pos = y_pos - 0.04;
    state.slice_slider = uicontrol(ctrl_panel, 'Style', 'slider', ...
        'Units', 'normalized', 'Position', [0.05 y_pos 0.7 0.03], ...
        'Min', 1, 'Max', state.num_slices, 'Value', state.current_slice, ...
        'SliderStep', [1/(state.num_slices-1) 10/(state.num_slices-1)], ...
        'Callback', @sliceChanged);

    state.slice_text = uicontrol(ctrl_panel, 'Style', 'text', ...
        'String', sprintf('%d/%d', state.current_slice, state.num_slices), ...
        'Units', 'normalized', 'Position', [0.76 y_pos 0.22 0.03], ...
        'FontSize', 9, 'FontWeight', 'bold', ...
        'BackgroundColor', [0.2 0.2 0.2], 'ForegroundColor', 'w');

    % --- Echo Selection ---
    y_pos = y_pos - 0.05;
    uicontrol(ctrl_panel, 'Style', 'text', ...
        'String', 'Echo Selection', ...
        'Units', 'normalized', 'Position', [0.05 y_pos 0.9 0.03], ...
        'FontSize', 9, 'FontWeight', 'bold', ...
        'BackgroundColor', [0.2 0.2 0.2], 'ForegroundColor', [0.9 0.7 0.2]);

    y_pos = y_pos - 0.04;
    state.echo_slider = uicontrol(ctrl_panel, 'Style', 'slider', ...
        'Units', 'normalized', 'Position', [0.05 y_pos 0.7 0.03], ...
        'Min', 1, 'Max', state.num_echoes, 'Value', state.current_echo, ...
        'SliderStep', [1/(state.num_echoes-1) 1/(state.num_echoes-1)], ...
        'Callback', @echoChanged);

    state.echo_text = uicontrol(ctrl_panel, 'Style', 'text', ...
        'String', sprintf('%d/%d', state.current_echo, state.num_echoes), ...
        'Units', 'normalized', 'Position', [0.76 y_pos 0.22 0.03], ...
        'FontSize', 9, 'FontWeight', 'bold', ...
        'BackgroundColor', [0.2 0.2 0.2], 'ForegroundColor', 'w');

    % --- Display Mode ---
    y_pos = y_pos - 0.05;
    uicontrol(ctrl_panel, 'Style', 'text', ...
        'String', 'Display Mode', ...
        'Units', 'normalized', 'Position', [0.05 y_pos 0.9 0.03], ...
        'FontSize', 9, 'FontWeight', 'bold', ...
        'BackgroundColor', [0.2 0.2 0.2], 'ForegroundColor', [0.9 0.7 0.2]);

    y_pos = y_pos - 0.04;
    state.mode_popup = uicontrol(ctrl_panel, 'Style', 'popupmenu', ...
        'String', {'Magnitude', 'Phase', 'Real Part', 'Imaginary Part'}, ...
        'Units', 'normalized', 'Position', [0.05 y_pos 0.9 0.035], ...
        'FontSize', 9, 'Value', 1, ...
        'Callback', @modeChanged);

    % --- Normalisation ---
    y_pos = y_pos - 0.055;
    uicontrol(ctrl_panel, 'Style', 'text', ...
        'String', 'Normalization', ...
        'Units', 'normalized', 'Position', [0.05 y_pos 0.9 0.03], ...
        'FontSize', 9, 'FontWeight', 'bold', ...
        'BackgroundColor', [0.2 0.2 0.2], 'ForegroundColor', [0.9 0.2 0.2]);

    y_pos = y_pos - 0.04;
    state.norm_popup = uicontrol(ctrl_panel, 'Style', 'popupmenu', ...
        'String', {'None (Raw)', 'Per-Slice [0,1]', 'Global [0,1]', 'Percentile (1-99%)'}, ...
        'Units', 'normalized', 'Position', [0.05 y_pos 0.9 0.035], ...
        'FontSize', 9, 'Value', 1, ...
        'Callback', @normChanged);

    % --- Colormap ---
    y_pos = y_pos - 0.055;
    uicontrol(ctrl_panel, 'Style', 'text', ...
        'String', 'Colormap', ...
        'Units', 'normalized', 'Position', [0.05 y_pos 0.45 0.03], ...
        'FontSize', 9, 'FontWeight', 'bold', ...
        'BackgroundColor', [0.2 0.2 0.2], 'ForegroundColor', [0.9 0.7 0.2]);
    uicontrol(ctrl_panel, 'Style', 'text', ...
        'String', 'Diff Cmap', ...
        'Units', 'normalized', 'Position', [0.5 y_pos 0.45 0.03], ...
        'FontSize', 9, 'FontWeight', 'bold', ...
        'BackgroundColor', [0.2 0.2 0.2], 'ForegroundColor', [0.9 0.7 0.2]);

    y_pos = y_pos - 0.04;
    state.cmap_popup = uicontrol(ctrl_panel, 'Style', 'popupmenu', ...
        'String', {'Gray', 'Jet', 'Hot', 'Parula', 'Turbo'}, ...
        'Units', 'normalized', 'Position', [0.05 y_pos 0.43 0.035], ...
        'FontSize', 9, 'Value', 1, ...
        'Callback', @cmapChanged);

    state.diff_cmap_popup = uicontrol(ctrl_panel, 'Style', 'popupmenu', ...
        'String', {'Hot', 'Jet', 'Parula', 'Turbo'}, ...
        'Units', 'normalized', 'Position', [0.52 y_pos 0.43 0.035], ...
        'FontSize', 9, 'Value', 1, ...
        'Callback', @(~,~) updateDisplay());

    % --- Diff Scale ---
    y_pos = y_pos - 0.05;
    uicontrol(ctrl_panel, 'Style', 'text', ...
        'String', 'Diff Amplification', ...
        'Units', 'normalized', 'Position', [0.05 y_pos 0.9 0.03], ...
        'FontSize', 9, 'FontWeight', 'bold', ...
        'BackgroundColor', [0.2 0.2 0.2], 'ForegroundColor', [0.9 0.7 0.2]);

    y_pos = y_pos - 0.04;
    state.diff_scale_slider = uicontrol(ctrl_panel, 'Style', 'slider', ...
        'Units', 'normalized', 'Position', [0.05 y_pos 0.7 0.03], ...
        'Min', 1, 'Max', 20, 'Value', 5, ...
        'SliderStep', [1/19 3/19], ...
        'Callback', @(~,~) updateDisplay());

    state.diff_scale_text = uicontrol(ctrl_panel, 'Style', 'text', ...
        'String', 'x5', ...
        'Units', 'normalized', 'Position', [0.76 y_pos 0.22 0.03], ...
        'FontSize', 9, 'FontWeight', 'bold', ...
        'BackgroundColor', [0.2 0.2 0.2], 'ForegroundColor', 'w');

    % --- Display Window (Floor / Ceiling) ---
    y_pos = y_pos - 0.05;
    uicontrol(ctrl_panel, 'Style', 'text', ...
        'String', 'Display Window (Background)', ...
        'Units', 'normalized', 'Position', [0.05 y_pos 0.9 0.03], ...
        'FontSize', 9, 'FontWeight', 'bold', ...
        'BackgroundColor', [0.2 0.2 0.2], 'ForegroundColor', [1.0 0.5 0.0]);

    % Floor slider
    y_pos = y_pos - 0.035;
    uicontrol(ctrl_panel, 'Style', 'text', ...
        'String', 'Floor', ...
        'Units', 'normalized', 'Position', [0.05 y_pos 0.15 0.03], ...
        'FontSize', 8, 'BackgroundColor', [0.2 0.2 0.2], 'ForegroundColor', [0.8 0.8 0.8]);

    state.floor_slider = uicontrol(ctrl_panel, 'Style', 'slider', ...
        'Units', 'normalized', 'Position', [0.2 y_pos 0.55 0.03], ...
        'Min', 0, 'Max', 1, 'Value', 0, ...
        'SliderStep', [0.005 0.05], ...
        'Callback', @floorChanged);

    state.floor_text = uicontrol(ctrl_panel, 'Style', 'text', ...
        'String', '0%', ...
        'Units', 'normalized', 'Position', [0.76 y_pos 0.22 0.03], ...
        'FontSize', 9, 'FontWeight', 'bold', ...
        'BackgroundColor', [0.2 0.2 0.2], 'ForegroundColor', [1.0 0.5 0.0]);

    % Ceiling slider
    y_pos = y_pos - 0.035;
    uicontrol(ctrl_panel, 'Style', 'text', ...
        'String', 'Ceil', ...
        'Units', 'normalized', 'Position', [0.05 y_pos 0.15 0.03], ...
        'FontSize', 8, 'BackgroundColor', [0.2 0.2 0.2], 'ForegroundColor', [0.8 0.8 0.8]);

    state.ceil_slider = uicontrol(ctrl_panel, 'Style', 'slider', ...
        'Units', 'normalized', 'Position', [0.2 y_pos 0.55 0.03], ...
        'Min', 0, 'Max', 1, 'Value', 1, ...
        'SliderStep', [0.005 0.05], ...
        'Callback', @ceilChanged);

    state.ceil_text = uicontrol(ctrl_panel, 'Style', 'text', ...
        'String', '100%', ...
        'Units', 'normalized', 'Position', [0.76 y_pos 0.22 0.03], ...
        'FontSize', 9, 'FontWeight', 'bold', ...
        'BackgroundColor', [0.2 0.2 0.2], 'ForegroundColor', [1.0 0.5 0.0]);

    % Preset buttons row
    y_pos = y_pos - 0.04;
    uicontrol(ctrl_panel, 'Style', 'pushbutton', ...
        'String', 'Auto', ...
        'Units', 'normalized', 'Position', [0.05 y_pos 0.2 0.035], ...
        'FontSize', 8, 'FontWeight', 'bold', ...
        'BackgroundColor', [0.35 0.35 0.35], 'ForegroundColor', 'w', ...
        'TooltipString', 'Reset to full range (Floor=0%, Ceiling=100%)', ...
        'Callback', @(~,~) setWindow(0, 1));

    uicontrol(ctrl_panel, 'Style', 'pushbutton', ...
        'String', 'BG Low', ...
        'Units', 'normalized', 'Position', [0.27 y_pos 0.22 0.035], ...
        'FontSize', 8, 'FontWeight', 'bold', ...
        'BackgroundColor', [0.6 0.35 0.1], 'ForegroundColor', 'w', ...
        'TooltipString', 'Show background: Floor=0%, Ceiling=5%', ...
        'Callback', @(~,~) setWindow(0, 0.05));

    uicontrol(ctrl_panel, 'Style', 'pushbutton', ...
        'String', 'BG Mid', ...
        'Units', 'normalized', 'Position', [0.51 y_pos 0.22 0.035], ...
        'FontSize', 8, 'FontWeight', 'bold', ...
        'BackgroundColor', [0.7 0.45 0.1], 'ForegroundColor', 'w', ...
        'TooltipString', 'Show background: Floor=0%, Ceiling=15%', ...
        'Callback', @(~,~) setWindow(0, 0.15));

    uicontrol(ctrl_panel, 'Style', 'pushbutton', ...
        'String', 'BG High', ...
        'Units', 'normalized', 'Position', [0.75 y_pos 0.22 0.035], ...
        'FontSize', 8, 'FontWeight', 'bold', ...
        'BackgroundColor', [0.8 0.55 0.1], 'ForegroundColor', 'w', ...
        'TooltipString', 'Show background: Floor=0%, Ceiling=30%', ...
        'Callback', @(~,~) setWindow(0, 0.30));

    % --- Link Color Limits ---
    y_pos = y_pos - 0.04;
    state.link_clim_cb = uicontrol(ctrl_panel, 'Style', 'checkbox', ...
        'String', ' Link Color Limits', ...
        'Units', 'normalized', 'Position', [0.05 y_pos 0.9 0.03], ...
        'FontSize', 8, 'FontWeight', 'bold', ...
        'BackgroundColor', [0.2 0.2 0.2], 'ForegroundColor', [0.9 0.7 0.2], ...
        'Value', 0, ...
        'Callback', @linkClimChanged);

    % --- Data Range Info ---
    y_pos = y_pos - 0.09;
    state.range_text = uicontrol(ctrl_panel, 'Style', 'text', ...
        'String', '', ...
        'Units', 'normalized', 'Position', [0.05 y_pos 0.9 0.09], ...
        'FontSize', 7, ...
        'BackgroundColor', [0.15 0.15 0.15], 'ForegroundColor', [0.7 0.7 0.9], ...
        'HorizontalAlignment', 'left', 'Max', 10);

    % --- Metrics Display ---
    y_pos = y_pos - 0.04;
    uicontrol(ctrl_panel, 'Style', 'text', ...
        'String', 'Quality Metrics', ...
        'Units', 'normalized', 'Position', [0.05 y_pos 0.9 0.03], ...
        'FontSize', 9, 'FontWeight', 'bold', ...
        'BackgroundColor', [0.2 0.2 0.2], 'ForegroundColor', [0.2 0.8 0.2]);

    y_pos = y_pos - 0.16;
    state.metrics_text = uicontrol(ctrl_panel, 'Style', 'text', ...
        'String', 'Load both datasets to see metrics', ...
        'Units', 'normalized', 'Position', [0.05 y_pos 0.9 0.16], ...
        'FontSize', 8, ...
        'BackgroundColor', [0.15 0.15 0.15], 'ForegroundColor', [0.8 0.9 0.8], ...
        'HorizontalAlignment', 'left', 'Max', 10);

    % --- Export Buttons ---
    y_pos = y_pos - 0.045;
    uicontrol(ctrl_panel, 'Style', 'pushbutton', ...
        'String', 'Export View', ...
        'Units', 'normalized', 'Position', [0.05 y_pos 0.43 0.04], ...
        'FontSize', 9, 'FontWeight', 'bold', ...
        'BackgroundColor', [0.6 0.4 0.2], 'ForegroundColor', 'w', ...
        'Callback', @exportView);

    uicontrol(ctrl_panel, 'Style', 'pushbutton', ...
        'String', 'Export Echoes', ...
        'Units', 'normalized', 'Position', [0.52 y_pos 0.43 0.04], ...
        'FontSize', 9, 'FontWeight', 'bold', ...
        'BackgroundColor', [0.5 0.3 0.5], 'ForegroundColor', 'w', ...
        'Callback', @exportAllEchoes);

    y_pos = y_pos - 0.045;
    uicontrol(ctrl_panel, 'Style', 'pushbutton', ...
        'String', 'ROI Analysis', ...
        'Units', 'normalized', 'Position', [0.05 y_pos 0.9 0.04], ...
        'FontSize', 9, 'FontWeight', 'bold', ...
        'BackgroundColor', [0.2 0.5 0.6], 'ForegroundColor', 'w', ...
        'Callback', @roiAnalysis);

    %% ---- Image Display Axes ----
    state.ax_gt = axes(fig, 'Units', 'normalized', ...
        'Position', [0.20 0.28 0.26 0.62], 'Color', [0 0 0]);
    title(state.ax_gt, 'Ground Truth', 'Color', 'w', 'FontSize', 12, 'FontWeight', 'bold');
    axis(state.ax_gt, 'image', 'off');

    state.ax_mc = axes(fig, 'Units', 'normalized', ...
        'Position', [0.48 0.28 0.26 0.62], 'Color', [0 0 0]);
    title(state.ax_mc, 'Motion Corrected', 'Color', 'w', 'FontSize', 12, 'FontWeight', 'bold');
    axis(state.ax_mc, 'image', 'off');

    state.ax_diff = axes(fig, 'Units', 'normalized', ...
        'Position', [0.76 0.28 0.23 0.62], 'Color', [0 0 0]);
    title(state.ax_diff, 'Difference', 'Color', 'w', 'FontSize', 12, 'FontWeight', 'bold');
    axis(state.ax_diff, 'image', 'off');

    state.ax_profile = axes(fig, 'Units', 'normalized', ...
        'Position', [0.20 0.04 0.78 0.20], ...
        'Color', [0.1 0.1 0.1], 'XColor', 'w', 'YColor', 'w');
    title(state.ax_profile, 'Line Profile (middle row)', 'Color', 'w', 'FontSize', 10);
    xlabel(state.ax_profile, 'Column', 'Color', 'w');
    ylabel(state.ax_profile, 'Intensity', 'Color', 'w');
    grid(state.ax_profile, 'on');
    state.ax_profile.GridColor = [0.3 0.3 0.3];

    %% ---- Keyboard Shortcuts ----
    set(fig, 'KeyPressFcn', @keyPress);

    %% =============== NESTED FUNCTIONS ===============

    % ---- Safe slider for N==1 ----
    function updateSliderSafe(slider_h, N, current_val)
        current_val = max(1, min(current_val, N));
        if N <= 1
            set(slider_h, 'Min', 1, 'Max', 1+eps, 'Value', 1, ...
                'SliderStep', [1 1], 'Enable', 'off');
        else
            set(slider_h, 'Min', 1, 'Max', N, 'Value', current_val, ...
                'SliderStep', [1/(N-1) min(10/(N-1),1)], 'Enable', 'on');
        end
    end

    % =========================================================
    % NEW: Return the number of slices for the current view
    %   Axial   -> dim 3 (kz)
    %   Coronal -> dim 2 (ky)
    %   Sagittal-> dim 1 (kx)
    % =========================================================
    function n = getNumSlicesForView()
        ref = state.gt_data;
        if isempty(ref); ref = state.mc_data; end
        if isempty(ref); n = state.num_slices; return; end
        sz = size(ref);
        switch state.view_mode
            case 1; n = sz(3);   % Axial
            case 2; n = sz(2);   % Coronal
            case 3; n = sz(1);   % Sagittal
            otherwise; n = sz(3);
        end
    end

    % =========================================================
    % NEW: Extract a 2-D complex slice from a 4-D array
    %   data  : (kx, ky, kz, echoes)
    %   s     : slice index within the current view
    %   e     : echo index
    % Returns a 2-D complex matrix.
    % =========================================================
    function slice_2d = extractSlice(data, s, e)
        switch state.view_mode
            case 1   % Axial: kx-ky plane, iterate over kz
                slice_2d = data(:, :, s, e);
            case 2   % Coronal: kx-kz plane, iterate over ky
                slice_2d = squeeze(data(:, s, :, e));
            case 3   % Sagittal: ky-kz plane, iterate over kx
                slice_2d = squeeze(data(s, :, :, e));
        end
    end

    % =========================================================
    % NEW: Return a human-readable label for the current view
    % =========================================================
    function lbl = viewLabel()
        labels = {'Axial', 'Coronal', 'Sagittal'};
        lbl = labels{state.view_mode};
    end

    % ---- Smart loader (matfile v7.3 + load fallback) ----
    function loadData(type)
        [fname, fpath] = uigetfile('*.mat', ['Select ' type ' data']);
        if isequal(fname, 0); return; end
        filepath = fullfile(fpath, fname);

        data = [];
        try
            mf = matfile(filepath, 'Writable', false);
            vars = whos(mf);
            use_matfile = true;
        catch
            use_matfile = false;
        end

        if use_matfile
            valid = arrayfun(@(v) numel(v.size) >= 4, vars);
            vars = vars(valid);
            if isempty(vars); errordlg('No 4-D variables found.'); return; end
            if numel(vars) == 1
                var_name = vars(1).name;
            else
                names = {vars.name};
                [sel,ok] = listdlg('PromptString','Select variable:','ListString',names,'SelectionMode','single');
                if ~ok; return; end
                var_name = names{sel};
            end
            sz = size(mf, var_name);
            nbytes = prod(sz)*16;
            fprintf('Loading "%s" via matfile (%s, %.1f GB)... ', var_name, mat2str(sz), nbytes/1e9);
            if nbytes > 4e9
                answer = questdlg(sprintf('Variable is %.1f GB. Load?',nbytes/1e9),'Large File','Yes','Cancel','Cancel');
                if ~strcmp(answer,'Yes'); return; end
            end
            data = mf.(var_name);
            fprintf('done.\n');
        else
            fprintf('Loading via load()... ');
            loaded = load(filepath);
            fields = fieldnames(loaded);
            valid_fields = fields(cellfun(@(f) ndims(loaded.(f))>=4, fields));
            if isempty(valid_fields); errordlg('No 4-D variables found.'); return; end
            if numel(valid_fields)==1
                var_name = valid_fields{1};
            else
                [sel,ok] = listdlg('PromptString','Select variable:','ListString',valid_fields,'SelectionMode','single');
                if ~ok; return; end
                var_name = valid_fields{sel};
            end
            data = loaded.(var_name);
            clear loaded;
            fprintf('done.\n');
        end

        sz = size(data);
        if numel(sz) < 4; errordlg(sprintf('Expected 4D, got %s',mat2str(sz))); return; end

        switch type
            case 'gt'
                state.gt_data = data; state.gt_name = fname;
                set(state.gt_label,'String',sprintf('%s [%s]',fname,mat2str(sz)));
                % Always derive echo count from GT dim 4
                state.num_echoes = sz(4);
        case 'mc'
                state.mc_data = data; state.mc_name = fname;
                set(state.mc_label,'String',sprintf('%s [%s]',fname,mat2str(sz)));
        end

        % Update slice count for current view orientation
        state.num_slices = getNumSlicesForView();
        state.current_slice = max(1, min(state.current_slice, state.num_slices));
        state.current_echo  = max(1, min(state.current_echo,  state.num_echoes));

        updateSliderSafe(state.slice_slider, state.num_slices, state.current_slice);
        updateSliderSafe(state.echo_slider,  state.num_echoes, state.current_echo);
        set(state.slice_text,'String',sprintf('%d/%d',state.current_slice,state.num_slices));
        set(state.echo_text,'String',sprintf('%d/%d',state.current_echo,state.num_echoes));

        state.data_loaded = ~isempty(state.gt_data) && ~isempty(state.mc_data);
        updateDisplay();
    end

    function loadDemoData()
        fprintf('Generating demo data (256x190x96x10)...\n');
        [X,Y] = meshgrid(linspace(-1,1,190), linspace(-1,1,256));
        bm = exp(-(X.^2+Y.^2)/0.3);
        brain = double(sqrt(X.^2+(Y*0.85).^2)<0.75);
        vent = double(sqrt((X*2).^2+((Y+0.05)*3).^2)<0.3);
        les1 = double(sqrt(((X-0.3)*5).^2+((Y-0.2)*5).^2)<0.4)*0.7;
        les2 = double(sqrt(((X+0.25)*6).^2+((Y+0.15)*6).^2)<0.35)*0.5;
        anat = max(brain.*(0.8+0.4*bm)-0.5*vent+les1+les2, 0);
        gt=zeros(256,190,96,10); mc=zeros(256,190,96,10);
        for sl=1:96; ss=exp(-((sl-48)/30)^2);
            for ec=1:10; td=exp(-ec*0.05); ph=2*pi*(0.02*ec)*(X+Y);
                gc=anat*ss*td.*exp(1i*ph); gt(:,:,sl,ec)=gc;
                mc(:,:,sl,ec)=gc.*(1+(0.02+0.01*rand())*randn(256,190)).*exp(1i*0.05*randn(256,190));
        end; end
        state.gt_data=gt; state.mc_data=mc;
        state.gt_name='Demo GT'; state.mc_name='Demo MC';
        state.num_echoes=10;
        set(state.gt_label,'String','Demo Ground Truth [256x190x96x10]');
        set(state.mc_label,'String','Demo Motion Corrected [256x190x96x10]');

        % Reset to axial and midpoint
        state.view_mode = 1;
        set(state.view_popup, 'Value', 1);
        state.num_slices = getNumSlicesForView();   % = 96
        state.current_slice = round(state.num_slices/2);
        state.current_echo  = 1;

        updateSliderSafe(state.slice_slider, state.num_slices, state.current_slice);
        updateSliderSafe(state.echo_slider,  state.num_echoes, state.current_echo);
        set(state.slice_text,'String',sprintf('%d/%d',state.current_slice,state.num_slices));
        set(state.echo_text,'String','1/10');
        state.data_loaded=true;
        fprintf('Demo data loaded.\n');
        updateDisplay();
    end

    %% ---- Slider / Popup Callbacks ----
    function sliceChanged(~,~)
        val = round(get(state.slice_slider,'Value'));
        state.current_slice = max(1,min(val,state.num_slices));
        set(state.slice_slider,'Value',state.current_slice);
        set(state.slice_text,'String',sprintf('%d/%d',state.current_slice,state.num_slices));
        updateDisplay();
    end
    function echoChanged(~,~)
        val = round(get(state.echo_slider,'Value'));
        state.current_echo = max(1,min(val,state.num_echoes));
        set(state.echo_slider,'Value',state.current_echo);
        set(state.echo_text,'String',sprintf('%d/%d',state.current_echo,state.num_echoes));
        updateDisplay();
    end
    function modeChanged(~,~);    state.display_mode    = get(state.mode_popup,'Value');  updateDisplay(); end
    function cmapChanged(~,~);    state.colormap_choice = get(state.cmap_popup,'Value');  updateDisplay(); end
    function linkClimChanged(~,~);state.link_clim       = logical(get(state.link_clim_cb,'Value')); updateDisplay(); end
    function normChanged(~,~);    state.norm_mode       = get(state.norm_popup,'Value');  updateDisplay(); end

    % =========================================================
    % NEW: View orientation changed
    %   1) Store the new view_mode
    %   2) Recalculate num_slices from the corresponding dimension
    %   3) Jump to midpoint of that dimension
    %   4) Refresh the slider and redisplay
    % =========================================================
    function viewChanged(~,~)
        state.view_mode = get(state.view_popup, 'Value');
        state.num_slices = getNumSlicesForView();
        state.current_slice = round(state.num_slices / 2);
        state.current_slice = max(1, state.current_slice);

        updateSliderSafe(state.slice_slider, state.num_slices, state.current_slice);
        set(state.slice_text, 'String', sprintf('%d/%d', state.current_slice, state.num_slices));
        updateDisplay();
    end

    % ---- Window Floor/Ceiling callbacks ----
    function floorChanged(~,~)
        val = get(state.floor_slider, 'Value');
        if val >= state.win_ceiling
            val = state.win_ceiling - 0.005;
            set(state.floor_slider, 'Value', val);
        end
        state.win_floor = val;
        set(state.floor_text, 'String', sprintf('%.1f%%', val*100));
        updateDisplay();
    end

    function ceilChanged(~,~)
        val = get(state.ceil_slider, 'Value');
        if val <= state.win_floor
            val = state.win_floor + 0.005;
            set(state.ceil_slider, 'Value', val);
        end
        state.win_ceiling = val;
        set(state.ceil_text, 'String', sprintf('%.1f%%', val*100));
        updateDisplay();
    end

    function setWindow(floor_val, ceil_val)
        state.win_floor = floor_val;
        state.win_ceiling = ceil_val;
        set(state.floor_slider, 'Value', floor_val);
        set(state.ceil_slider,  'Value', ceil_val);
        set(state.floor_text, 'String', sprintf('%.1f%%', floor_val*100));
        set(state.ceil_text,  'String', sprintf('%.1f%%', ceil_val*100));
        updateDisplay();
    end

    %% ---- Normalisation helpers ----
    function [go,mo] = normalizeSlices(gi,mi)
        switch state.norm_mode
            case 1; go=gi; mo=mi;
            case 2; go=norm01(gi); mo=norm01(mi);
            case 3
                jn=min(min(gi(:)),min(mi(:))); jx=max(max(gi(:)),max(mi(:)));
                if jx>jn; go=(gi-jn)/(jx-jn); mo=(mi-jn)/(jx-jn); else; go=gi; mo=mi; end
            case 4; go=normPrctile(gi); mo=normPrctile(mi);
        end
    end
    function out=norm01(img)
        mn=min(img(:)); mx=max(img(:));
        if mx>mn; out=(img-mn)/(mx-mn); else; out=img; end
    end
    function out=normPrctile(img)
        p1=prctile(img(:),1); p99=prctile(img(:),99);
        if p99>p1; out=max(min((img-p1)/(p99-p1),1),0); else; out=img; end
    end

    %% ---- Display helpers ----
    function img=applyDisplayMode(cd)
        switch state.display_mode
            case 1; img=abs(cd);   case 2; img=angle(cd);
            case 3; img=real(cd);  case 4; img=imag(cd);
        end
    end
    function cmap=getColormap(choice,n)
        if nargin<2; n=256; end
        switch choice
            case 1; cmap=gray(n);   case 2; cmap=jet(n);  case 3; cmap=hot(n);
            case 4; cmap=parula(n); case 5; cmap=turbo(n); otherwise; cmap=gray(n);
        end
    end
    function di=computeDifference(gc,mc,gd,md)
        if state.display_mode==2; di=angle(gc.*conj(mc)); else; di=abs(gd-md); end
    end

    function cl = computeWindowedClim(img)
        mn = min(img(:)); mx = max(img(:));
        rng = mx - mn;
        if rng == 0; cl = [mn mn+1]; return; end
        cl_lo = mn + state.win_floor  * rng;
        cl_hi = mn + state.win_ceiling * rng;
        if cl_hi <= cl_lo; cl_hi = cl_lo + eps; end
        cl = [cl_lo cl_hi];
    end

    %% ---- Main Display Update ----
    function updateDisplay()
        if isempty(state.gt_data) && isempty(state.mc_data); return; end

        s = state.current_slice; e = state.current_echo;
        mode_names = {'Magnitude','Phase','Real Part','Imaginary Part'};
        diff_scale = round(get(state.diff_scale_slider,'Value'));
        set(state.diff_scale_text,'String',sprintf('x%d',diff_scale));

        cmap_main = getColormap(state.colormap_choice);
        cmap_diff = getColormap(get(state.diff_cmap_popup,'Value'));

        % ---- Extract slice using view-aware helper ----
        gt_complex=[]; mc_complex=[]; gt_slice_raw=[]; mc_slice_raw=[];
        if ~isempty(state.gt_data)
            gt_complex   = extractSlice(state.gt_data, s, e);
            gt_slice_raw = applyDisplayMode(gt_complex);
        end
        if ~isempty(state.mc_data)
            mc_complex   = extractSlice(state.mc_data, s, e);
            mc_slice_raw = applyDisplayMode(mc_complex);
        end

        % Normalise (skip for Phase)
        if ~isempty(gt_slice_raw) && ~isempty(mc_slice_raw)
            if state.display_mode==2; gt_slice=gt_slice_raw; mc_slice=mc_slice_raw;
            else; [gt_slice,mc_slice]=normalizeSlices(gt_slice_raw,mc_slice_raw); end
        else; gt_slice=gt_slice_raw; mc_slice=mc_slice_raw; end

        norm_names={'Raw','Per-Slice [0,1]','Global [0,1]','Percentile'};
        if state.display_mode==2; norm_str='Phase'; else; norm_str=norm_names{state.norm_mode}; end

        % Window string for title
        if state.win_floor > 0 || state.win_ceiling < 1
            win_str = sprintf(' | W[%.0f-%.0f%%]', state.win_floor*100, state.win_ceiling*100);
        else
            win_str = '';
        end

        % View label for titles
        vlbl = viewLabel();

        % Display GT with windowing
        if ~isempty(gt_slice)
            cl_gt = computeWindowedClim(gt_slice);
            axes(state.ax_gt);
            imagesc(gt_slice, cl_gt); axis image off;
            colormap(state.ax_gt, cmap_main); colorbar(state.ax_gt,'Color','w');
            title(state.ax_gt, sprintf('GT | %s | %s S%d E%d | %s%s', ...
                mode_names{state.display_mode}, vlbl, s, e, norm_str, win_str), ...
                'Color','w','FontSize',9,'FontWeight','bold');
        end

        % Display MC with windowing
        if ~isempty(mc_slice)
            cl_mc = computeWindowedClim(mc_slice);
            axes(state.ax_mc);
            imagesc(mc_slice, cl_mc); axis image off;
            colormap(state.ax_mc, cmap_main); colorbar(state.ax_mc,'Color','w');
            title(state.ax_mc, sprintf('MC | %s | %s S%d E%d | %s%s', ...
                mode_names{state.display_mode}, vlbl, s, e, norm_str, win_str), ...
                'Color','w','FontSize',9,'FontWeight','bold');
        end

        % Link color limits (applied after windowing)
        if ~isempty(gt_slice) && ~isempty(mc_slice) && state.link_clim
            cl = [min(cl_gt(1),cl_mc(1)), max(cl_gt(2),cl_mc(2))];
            if cl(1)<cl(2); caxis(state.ax_gt,cl); caxis(state.ax_mc,cl); end
        end

        % Range info
        if ~isempty(gt_slice_raw) && ~isempty(mc_slice_raw)
            range_str = sprintf('RAW: GT[%.2g,%.2g] MC[%.2g,%.2g]\nNORM: GT[%.3f,%.3f] MC[%.3f,%.3f]\nWindow: [%.1f%%-%.1f%%]', ...
                min(gt_slice_raw(:)),max(gt_slice_raw(:)), ...
                min(mc_slice_raw(:)),max(mc_slice_raw(:)), ...
                min(gt_slice(:)),max(gt_slice(:)), ...
                min(mc_slice(:)),max(mc_slice(:)), ...
                state.win_floor*100, state.win_ceiling*100);
            set(state.range_text,'String',range_str);
        end

        % Difference map and metrics
        if state.data_loaded
            diff_img = computeDifference(gt_complex,mc_complex,gt_slice,mc_slice);
            axes(state.ax_diff);
            if state.display_mode==2
                imagesc(diff_img,[-pi pi]); axis image off;
                colormap(state.ax_diff,cmap_diff);
                cb=colorbar(state.ax_diff,'Color','w'); ylabel(cb,'rad');
                title(state.ax_diff,sprintf('Phase Diff: \\angle(GT\\cdotMC*) | %s',vlbl),...
                    'Color','w','FontSize',9,'FontWeight','bold');
            else
                diff_display = diff_img * diff_scale;
                imagesc(diff_display); axis image off;
                colormap(state.ax_diff,cmap_diff); colorbar(state.ax_diff,'Color','w');
                title(state.ax_diff,sprintf('|Difference| x%d | %s',diff_scale,vlbl),...
                    'Color','w','FontSize',10,'FontWeight','bold');
            end

            % Metrics
            gt_mag_raw=abs(gt_complex); mc_mag_raw=abs(mc_complex);
            gt_max_raw=max(gt_mag_raw(:)); mc_max_raw=max(mc_mag_raw(:));
            gt_mag=norm01(gt_mag_raw); mc_mag=norm01(mc_mag_raw);

            rmse_val=sqrt(mean((gt_mag(:)-mc_mag(:)).^2));
            rng_val=max(gt_mag(:))-min(gt_mag(:));
            if rng_val>0; nrmse_val=rmse_val/rng_val*100; else; nrmse_val=0; end
            mse_val=mean((gt_mag(:)-mc_mag(:)).^2);
            if mse_val>0; psnr_val=10*log10(1/mse_val); else; psnr_val=Inf; end
            ssim_val = compute_ssim(gt_mag,mc_mag);
            if std(gt_mag(:))>0 && std(mc_mag(:))>0; corr_val=corr(gt_mag(:),mc_mag(:)); else; corr_val=NaN; end
            phase_diff=angle(gt_complex.*conj(mc_complex));
            phase_rmse_deg=rad2deg(sqrt(mean(phase_diff(:).^2)));

            metrics_str = sprintf([ ...
                'SSIM:       %.4f\n' ...
                'PSNR:       %.2f dB\n' ...
                'RMSE:       %.4f\n' ...
                'NRMSE:      %.2f%%\n' ...
                'Corr:       %.4f\n' ...
                'Phase RMSE: %.2f deg\n' ...
                'GT max: %.2g | MC max: %.2g'], ...
                ssim_val,psnr_val,rmse_val,nrmse_val, ...
                corr_val,phase_rmse_deg,gt_max_raw,mc_max_raw);
            set(state.metrics_text,'String',metrics_str);

            % Line profile (middle row of the 2-D slice)
            mid_row=round(size(gt_slice,1)/2);
            gp=gt_slice(mid_row,:); mp=mc_slice(mid_row,:);
            axes(state.ax_profile); cla(state.ax_profile); hold(state.ax_profile,'on');
            plot(state.ax_profile,gp,'g-','LineWidth',1.5,'DisplayName','Ground Truth');
            plot(state.ax_profile,mp,'c-','LineWidth',1.5,'DisplayName','Motion Corrected');
            if state.display_mode==2
                dp=angle(gt_complex(mid_row,:).*conj(mc_complex(mid_row,:)));
                plot(state.ax_profile,dp,'r-','LineWidth',1,'DisplayName','Phase Diff (rad)');
            else
                plot(state.ax_profile,abs(gp-mp)*diff_scale,'r-','LineWidth',1,...
                    'DisplayName',sprintf('|Diff| x%d',diff_scale));
            end
            hold(state.ax_profile,'off');
            legend(state.ax_profile,'show','TextColor','w','Color',[0.2 0.2 0.2],...
                'Location','northeast','FontSize',7);
            title(state.ax_profile,sprintf('Line Profile (Row %d) | %s',mid_row,vlbl),...
                'Color','w','FontSize',9);
            xlabel(state.ax_profile,'Column','Color','w');
            ylabel(state.ax_profile,mode_names{state.display_mode},'Color','w');
            grid(state.ax_profile,'on');
            set(state.ax_profile,'Color',[0.1 0.1 0.1],'XColor','w','YColor','w',...
                'GridColor',[0.3 0.3 0.3]);

            % Window range lines on profile
            if state.display_mode ~= 2 && (state.win_floor > 0 || state.win_ceiling < 1)
                hold(state.ax_profile, 'on');
                xl = xlim(state.ax_profile);
                mn_gt = min(gt_slice(:)); mx_gt = max(gt_slice(:));
                rng_gt = mx_gt - mn_gt;
                floor_line = mn_gt + state.win_floor  * rng_gt;
                ceil_line  = mn_gt + state.win_ceiling * rng_gt;
                plot(state.ax_profile, xl, [floor_line floor_line], 'y--', 'LineWidth', 1, 'DisplayName', 'Floor');
                plot(state.ax_profile, xl, [ceil_line  ceil_line],  'y--', 'LineWidth', 1, 'DisplayName', 'Ceiling');
                hold(state.ax_profile, 'off');
            end
        end
        drawnow;
    end

    % ---- Toolbox-free SSIM (conv2) ----
    function ssim_val=compute_ssim(img1,img2)
        C1=(0.01)^2; C2=(0.03)^2;
        w=11; sigma=1.5;
        [x,y]=meshgrid(-(w-1)/2:(w-1)/2);
        g=exp(-(x.^2+y.^2)/(2*sigma^2)); g=g/sum(g(:));
        mu1=conv2(img1,g,'same'); mu2=conv2(img2,g,'same');
        mu1sq=mu1.^2; mu2sq=mu2.^2; mu12=mu1.*mu2;
        s1sq=max(conv2(img1.^2,g,'same')-mu1sq,0);
        s2sq=max(conv2(img2.^2,g,'same')-mu2sq,0);
        s12=conv2(img1.*img2,g,'same')-mu12;
        ssim_map=((2*mu12+C1).*(2*s12+C2))./((mu1sq+mu2sq+C1).*(s1sq+s2sq+C2));
        ssim_val=mean(ssim_map(:));
    end

    %% ---- Keyboard Navigation ----
    function keyPress(~,event)
        switch event.Key
            case 'rightarrow'
                state.current_slice=min(state.current_slice+1,state.num_slices);
                set(state.slice_slider,'Value',state.current_slice);
                set(state.slice_text,'String',sprintf('%d/%d',state.current_slice,state.num_slices));
                updateDisplay();
            case 'leftarrow'
                state.current_slice=max(state.current_slice-1,1);
                set(state.slice_slider,'Value',state.current_slice);
                set(state.slice_text,'String',sprintf('%d/%d',state.current_slice,state.num_slices));
                updateDisplay();
            case 'uparrow'
                state.current_echo=min(state.current_echo+1,state.num_echoes);
                set(state.echo_slider,'Value',state.current_echo);
                set(state.echo_text,'String',sprintf('%d/%d',state.current_echo,state.num_echoes));
                updateDisplay();
            case 'downarrow'
                state.current_echo=max(state.current_echo-1,1);
                set(state.echo_slider,'Value',state.current_echo);
                set(state.echo_text,'String',sprintf('%d/%d',state.current_echo,state.num_echoes));
                updateDisplay();
        end
    end

    %% ---- Export ----
    function exportView(~,~)
        if ~state.data_loaded; errordlg('Load both datasets first.'); return; end
        [fname,fpath]=uiputfile({'*.png';'*.tiff';'*.fig'},'Save Current View');
        if isequal(fname,0); return; end
        s=state.current_slice; e=state.current_echo;
        mn={'Magnitude','Phase','Real Part','Imaginary Part'};
        % Use view-aware extraction
        gc = extractSlice(state.gt_data, s, e);
        mc_c = extractSlice(state.mc_data, s, e);
        gd=applyDisplayMode(gc); md=applyDisplayMode(mc_c);
        if state.display_mode~=2; [gd,md]=normalizeSlices(gd,md); end
        di=computeDifference(gc,mc_c,gd,md);
        ds=round(get(state.diff_scale_slider,'Value'));
        vlbl = viewLabel();
        ef=figure('Visible','off','Position',[100 100 1800 600],'Color','k');
        if state.display_mode~=2
            cl_gt=computeWindowedClim(gd); cl_mc=computeWindowedClim(md);
            cl=[min(cl_gt(1),cl_mc(1)) max(cl_gt(2),cl_mc(2))];
        else; cl=[-pi pi]; end
        ax1=subplot(1,3,1,'Parent',ef); imagesc(ax1,gd,cl); axis(ax1,'image','off');
        colormap(ax1,getColormap(state.colormap_choice)); colorbar(ax1);
        title(ax1,sprintf('GT|%s|%s|S%dE%d',mn{state.display_mode},vlbl,s,e),'FontSize',14);
        ax2=subplot(1,3,2,'Parent',ef); imagesc(ax2,md,cl); axis(ax2,'image','off');
        colormap(ax2,getColormap(state.colormap_choice)); colorbar(ax2);
        title(ax2,sprintf('MC|%s|%s|S%dE%d',mn{state.display_mode},vlbl,s,e),'FontSize',14);
        ax3=subplot(1,3,3,'Parent',ef);
        if state.display_mode==2; imagesc(ax3,di,[-pi pi]); else; imagesc(ax3,di*ds); end
        axis(ax3,'image','off');
        colormap(ax3,getColormap(get(state.diff_cmap_popup,'Value'))); colorbar(ax3);
        title(ax3,sprintf('Diff x%d',ds),'FontSize',14);
        saveas(ef,fullfile(fpath,fname)); close(ef);
        fprintf('Saved: %s\n',fullfile(fpath,fname));
    end

    function exportAllEchoes(~,~)
        if ~state.data_loaded; errordlg('Load both datasets first.'); return; end
        folder=uigetdir(pwd,'Select Output Folder');
        if isequal(folder,0); return; end
        s=state.current_slice; ms={'Mag','Phase','Real','Imag'}; mstr=ms{state.display_mode};
        vlbl = viewLabel();
        wb=waitbar(0,'Exporting...');
        for ec=1:state.num_echoes
            waitbar(ec/state.num_echoes,wb,sprintf('Echo %d/%d',ec,state.num_echoes));
            gc   = extractSlice(state.gt_data, s, ec);
            mc_c = extractSlice(state.mc_data, s, ec);
            gd=applyDisplayMode(gc); md=applyDisplayMode(mc_c);
            if state.display_mode~=2; [gd,md]=normalizeSlices(gd,md); end
            di=computeDifference(gc,mc_c,gd,md);
            ds=round(get(state.diff_scale_slider,'Value'));
            if state.display_mode~=2
                cg=computeWindowedClim(gd); cm=computeWindowedClim(md);
                cl=[min(cg(1),cm(1)) max(cg(2),cm(2))];
            else; cl=[-pi pi]; end
            ef=figure('Visible','off','Position',[100 100 1800 600]);
            ax1=subplot(1,3,1,'Parent',ef); imagesc(ax1,gd,cl); axis(ax1,'image','off');
            colormap(ax1,getColormap(state.colormap_choice)); colorbar(ax1);
            title(ax1,sprintf('GT %s %s S%d E%d',mstr,vlbl,s,ec),'FontSize',12);
            ax2=subplot(1,3,2,'Parent',ef); imagesc(ax2,md,cl); axis(ax2,'image','off');
            colormap(ax2,getColormap(state.colormap_choice)); colorbar(ax2);
            title(ax2,sprintf('MC %s %s S%d E%d',mstr,vlbl,s,ec),'FontSize',12);
            ax3=subplot(1,3,3,'Parent',ef);
            if state.display_mode==2; imagesc(ax3,di,[-pi pi]); else; imagesc(ax3,di*ds); end
            axis(ax3,'image','off');
            colormap(ax3,getColormap(get(state.diff_cmap_popup,'Value'))); colorbar(ax3);
            title(ax3,sprintf('Diff x%d',ds),'FontSize',12);
            saveas(ef,fullfile(folder,sprintf('comparison_%s_%s_slice%03d_echo%02d.png',...
                mstr,lower(vlbl),s,ec)));
            close(ef);
        end
        close(wb); fprintf('Exported %d echoes to: %s\n',state.num_echoes,folder);
    end

    function roiAnalysis(~,~)
        if ~state.data_loaded; errordlg('Load both datasets first.'); return; end
        s=state.current_slice; vlbl=viewLabel();
        rf=figure('Name',sprintf('Draw ROI on GT (%s)',vlbl),'NumberTitle','off');
        ref_slice = extractSlice(state.gt_data, s, state.current_echo);
        imagesc(norm01(abs(ref_slice))); axis image; colormap gray; colorbar;
        title(sprintf('Draw freehand ROI on %s slice %d, double-click to finish',vlbl,s));
        h=drawfreehand; mask=createMask(h); close(rf);
        fprintf('\n====== ROI Analysis (%s Slice %d) ======\n', vlbl, s);
        fprintf('%-6s %-9s %-9s %-11s %-9s %-9s\n','Echo','RMSE','PSNR(dB)','PhRMS(deg)','MeanGT','MeanMC');
        fprintf('-------------------------------------------------------\n');
        rv=zeros(1,state.num_echoes); pv=rv; phv=rv;
        for ei=1:state.num_echoes
            gs = extractSlice(state.gt_data, s, ei);
            ms_ = extractSlice(state.mc_data, s, ei);
            gn=norm01(abs(gs)); mn_=norm01(abs(ms_));
            gr=gn(mask); mr=mn_(mask);
            re=sqrt(mean((gr-mr).^2)); me=mean((gr-mr).^2);
            if me>0; pe=10*log10(1/me); else; pe=Inf; end
            pd=angle(gs.*conj(ms_));
            phe=rad2deg(sqrt(mean(pd(mask).^2)));
            rv(ei)=re; pv(ei)=pe; phv(ei)=phe;
            fprintf('%-6d %-9.4f %-9.2f %-11.2f %-9.4f %-9.4f\n',ei,re,pe,phe,mean(gr),mean(mr));
        end
        figure('Name','ROI Analysis','NumberTitle','off','Position',[200 200 1000 350]);
        subplot(1,3,1); plot(1:state.num_echoes,rv,'ro-','LineWidth',2,'MarkerFaceColor','r');
        xlabel('Echo'); ylabel('RMSE'); title(sprintf('RMSE/Echo (%s)',vlbl)); grid on; xlim([.5 state.num_echoes+.5]);
        subplot(1,3,2); bar(1:state.num_echoes,pv,'FaceColor',[.3 .6 .9]);
        xlabel('Echo'); ylabel('PSNR(dB)'); title(sprintf('PSNR/Echo (%s)',vlbl)); grid on; xlim([.5 state.num_echoes+.5]);
        subplot(1,3,3); plot(1:state.num_echoes,phv,'ms-','LineWidth',2,'MarkerFaceColor','m');
        xlabel('Echo'); ylabel('Phase RMSE(deg)'); title(sprintf('Phase RMSE/Echo (%s)',vlbl)); grid on; xlim([.5 state.num_echoes+.5]);
    end

    function closeFig(~,~); delete(fig); end
end
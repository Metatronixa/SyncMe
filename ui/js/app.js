(function () {
  'use strict';

  const WEEKDAYS = ['Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'];

  const state = {
    step: 0,
    snaps: [],
    selectedSnap: -1,
    resticOk: false,
    rcloneOk: false,
    winfspOk: false,
    activeSetId: 'set1',
    sets: [],
    isNewSet: false,
    pollTimer: null,
    pollTimerOauth: null,
    setupAppliedSetId: '',
    etaSamples: [],
    form: {
      operatorName: '',
      displayName: 'Backup set 1',
      confirmBackupPc: false,
      resticPath: 'restic',
      networkMode: 'both',
      sourceHost: '',
      sourcePaths: [''],
      destinationType: 'local',
      resticRepo: '',
      archivePath: '',
      createFolders: true,
      resticPassword: '',
      resticPassword2: '',
      storeShare: false,
      shareUser: '',
      sharePassword: '',
      sharePassword2: '',
      enableEmail: true,
      smtpServer: 'smtp.office365.com',
      smtpPort: '587',
      smtpSsl: true,
      mailFrom: '',
      mailTo: '',
      smtpUser: '',
      smtpPassword: '',
      smtpPassword2: '',
      runTime: '01:00',
      scheduleStartDate: '',
      scheduleRecurrence: 'Daily',
      scheduleEndDate: '',
      scheduleDaysOfWeek: WEEKDAYS.slice(),
      enableToast: false,
      taskLogonType: 'Password',
      windowsPassword: '',
      windowsPassword2: '',
      setId: '',
      useShadowCopy: true,
      enableWakeOnLan: false,
      wakeMac: '',
      keepLast: 7,
      keepDaily: 14,
      keepWeekly: 8,
      keepMonthly: 6,
      enableRepoCheck: true,
      weeklyDataCheckDay: 'Sunday',
      resticLimitUploadKByte: 0,
      rcloneRemote: '',
      rcloneSubPath: '',
      rcloneBwLimit: 'off',
      rcloneTransfers: 4,
      rcloneCheckers: 8,
      rcloneRetries: 3,
      rcloneLowLevelRetries: 10,
      rcloneMultiThreadStreams: 4
    }
  };

  if (!state.form.scheduleStartDate) {
    const t = new Date();
    state.form.scheduleStartDate = t.toISOString().slice(0, 10);
  }

  const steps = [
    { id: 'welcome', title: 'Welcome', sub: 'Configure SyncMe on this Backup PC. Passwords go in Windows Credential Manager — never in a config file.' },
    { id: 'prereqs', title: 'Prerequisites', sub: 'We check restic (and Tailscale if you use it). SyncMe can download restic, rclone, and WinFsp if missing.' },
    { id: 'source', title: 'Source folders', sub: 'Pull from LAN and/or Tailscale UNC shares (including admin $ shares). Add multiple folders to this backup set.' },
    { id: 'dest', title: 'Backup destination', sub: 'Versioned restic repository — local folder, NAS UNC, or cloud via rclone.' },
    { id: 'secrets', title: 'Passwords', sub: 'Choose a strong restic password and store it in a password manager too.' },
    { id: 'email', title: 'Email alerts', sub: 'Optional SMTP so you get start/complete reports.' },
    { id: 'schedule', title: 'Schedule', sub: 'Start date, time, and recurrence are written to Windows Task Scheduler — backups run with the console closed.' },
    { id: 'review', title: 'Review & apply', sub: 'SyncMe will write config, store secrets, initialize restic, and register the scheduled task.' }
  ];

  const $ = (id) => document.getElementById(id);
  const params = new URLSearchParams(location.search);
  const forceSetup = params.get('view') === 'setup';
  const forceConsole = params.get('view') === 'console';

  function setStatus(el, text, kind) {
    if (!el) return;
    el.className = 'status-line' + (kind ? ' ' + kind : '');
    el.textContent = text || '';
  }

  function setTop(text, kind) {
    const pill = $('topStatus');
    pill.className = 'chip ' + (kind || 'neutral');
    $('topStatusText').textContent = text;
  }

  function setStatCard(cardId, kind) {
    const el = $(cardId);
    if (!el) return;
    el.className = 'stat' + (kind ? ' ' + kind : '');
  }

  async function api(path, opts) {
    const res = await fetch(path, Object.assign({
      headers: { 'Content-Type': 'application/json' }
    }, opts || {}));
    const data = await res.json().catch(() => ({}));
    if (!res.ok || data.ok === false) {
      throw new Error(data.message || ('Request failed: ' + res.status));
    }
    return data;
  }

  function setNavActive(which) {
    document.querySelectorAll('.rail nav a').forEach((a) => {
      a.classList.toggle('active', a.getAttribute('data-nav') === which);
    });
  }

  function show(view) {
    ['view-setup', 'view-dash', 'view-ops'].forEach((id) => {
      const el = $(id);
      if (el) el.classList.add('hidden');
    });
    $(view).classList.remove('hidden');
    if (view === 'view-setup') setNavActive('setup');
    else if (view === 'view-dash') setNavActive('dash');
    else if (view === 'view-ops') setNavActive('ops');
    const sw = $('setSwitcher');
    if (sw) sw.style.display = (view === 'view-setup') ? 'none' : '';
    const dry = $('btnWizardDryRun');
    if (dry && view !== 'view-setup') dry.classList.add('hidden');
  }

  function openModal(id) {
    const m = $(id);
    if (m) m.classList.remove('hidden');
  }
  function closeModal(id) {
    const m = $(id);
    if (m) m.classList.add('hidden');
  }

  function renderSteps() {
    $('setupSteps').innerHTML = steps.map((s, i) => {
      let cls = 'step-chip';
      if (i === state.step) cls += ' active';
      else if (i < state.step) cls += ' done';
      return '<span class="' + cls + '">' + (i + 1) + '. ' + s.title + '</span>';
    }).join('');
  }

  function val(id) {
    const el = document.getElementById(id);
    return el ? String(el.value).trim() : '';
  }
  function checked(id) {
    const el = document.getElementById(id);
    return el ? !!el.checked : false;
  }

  function collectScheduleDays() {
    const days = [];
    WEEKDAYS.forEach((d) => {
      if (checked('fDay' + d)) days.push(d);
    });
    return days.length ? days : WEEKDAYS.slice();
  }

  function syncScheduleFieldsVisibility() {
    const rec = val('fRecurrence') || state.form.scheduleRecurrence || 'Daily';
    const endWrap = document.getElementById('schedEndWrap');
    const daysWrap = document.getElementById('schedDaysWrap');
    if (endWrap) endWrap.classList.toggle('hidden', rec === 'Once');
    if (daysWrap) daysWrap.classList.toggle('hidden', rec !== 'Weekly');
  }

  function collectForm() {
    const f = state.form;
    if (state.step === 0) {
      f.operatorName = val('fName');
      f.displayName = val('fDisplayName') || f.displayName;
      f.confirmBackupPc = checked('fConfirm');
    } else if (state.step === 1) {
      f.resticPath = val('fRestic') || 'restic';
    } else if (state.step === 2) {
      const modeEl = document.querySelector('input[name="fNetMode"]:checked');
      f.networkMode = modeEl ? modeEl.value : 'both';
      f.sourceHost = val('fHost');
      f.sourcePaths = collectPathList();
      f.useShadowCopy = checked('fShadow');
      f.enableWakeOnLan = checked('fWol');
      f.wakeMac = val('fMac');
    } else if (state.step === 3) {
      const destEl = document.querySelector('input[name="fDestType"]:checked');
      f.destinationType = destEl ? destEl.value : 'local';
      f.resticRepo = val('fRepo');
      f.archivePath = '';
      f.createFolders = checked('fCreate');
      if (f.destinationType === 'rclone') {
        f.rcloneRemote = val('fRcloneRemote');
        f.rcloneSubPath = val('fRclonePath');
        f.rcloneBwLimit = val('fBwLimit') || 'off';
        f.rcloneTransfers = parseInt(val('fTransfers') || '4', 10);
        f.rcloneRetries = parseInt(val('fRetries') || '3', 10);
        f.resticLimitUploadKByte = parseInt(val('fLimitUp') || '0', 10);
        const remote = (f.rcloneRemote || '').replace(/:$/, '');
        const sub = (f.rcloneSubPath || '').replace(/^\/+/, '');
        if (remote) {
          f.resticRepo = sub ? ('rclone:' + remote + ':' + sub) : ('rclone:' + remote + ':');
        }
      }
    } else if (state.step === 4) {
      f.resticPassword = val('fRestPass');
      f.resticPassword2 = val('fRestPass2');
      f.storeShare = checked('fStoreShare');
      f.shareUser = val('fShareUser');
      f.sharePassword = val('fSharePass');
      f.sharePassword2 = val('fSharePass2');
    } else if (state.step === 5) {
      f.enableEmail = checked('fEmail');
      f.smtpServer = val('fSmtp');
      f.smtpPort = val('fPort');
      f.smtpSsl = checked('fSsl');
      f.mailFrom = val('fFrom');
      f.mailTo = val('fTo');
      f.smtpUser = val('fSmtpUser');
      f.smtpPassword = val('fSmtpPass');
      f.smtpPassword2 = val('fSmtpPass2');
    } else if (state.step === 6) {
      f.runTime = val('fTime');
      f.scheduleStartDate = val('fStartDate');
      f.scheduleRecurrence = val('fRecurrence') || 'Daily';
      f.scheduleEndDate = val('fEndDate');
      f.scheduleDaysOfWeek = collectScheduleDays();
      f.enableToast = checked('fToast');
      f.taskLogonType = checked('fUnattended') ? 'Password' : 'Interactive';
      f.windowsPassword = val('fWinPass');
      f.windowsPassword2 = val('fWinPass2');
    }
  }

  function collectPathList() {
    const inputs = document.querySelectorAll('#pathList input.path-input');
    if (!inputs.length) return state.form.sourcePaths || [];
    return Array.from(inputs).map((i) => i.value.trim()).filter(Boolean);
  }

  function renderPathList() {
    const box = document.getElementById('pathList');
    if (!box) return;
    const paths = state.form.sourcePaths && state.form.sourcePaths.length ? state.form.sourcePaths : [''];
    box.innerHTML = paths.map((p, i) =>
      '<div class="path-row"><input class="path-input" type="text" data-i="' + i + '" value="' + esc(p) + '" />' +
      '<button type="button" class="btn ghost btn-rm-path" data-i="' + i + '">Remove</button></div>'
    ).join('');
    box.querySelectorAll('.btn-rm-path').forEach((b) => {
      b.onclick = () => {
        state.form.sourcePaths = collectPathList();
        state.form.sourcePaths.splice(parseInt(b.getAttribute('data-i'), 10), 1);
        if (!state.form.sourcePaths.length) state.form.sourcePaths = [''];
        renderPathList();
      };
    });
  }

  function scheduleSummary(f) {
    const rec = f.scheduleRecurrence || 'Daily';
    const time = f.runTime || '01:00';
    const start = f.scheduleStartDate || '';
    const end = f.scheduleEndDate || '';
    let s = rec + ' at ' + time;
    if (start) s += ' from ' + start;
    if (rec !== 'Once' && end) s += ' until ' + end;
    if (rec === 'Weekly' && f.scheduleDaysOfWeek && f.scheduleDaysOfWeek.length) {
      s += ' (' + f.scheduleDaysOfWeek.join(', ') + ')';
    }
    return s;
  }

  function renderSetupBody() {
    const f = state.form;
    const body = $('setupBody');
    const s = steps[state.step];
    $('setupTitle').textContent = s.title;
    $('setupSub').textContent = s.sub;
    $('btnNext').textContent = state.step === steps.length - 1 ? 'Apply' : 'Next';
    $('btnBack').disabled = state.step === 0;
    const dryBtn = $('btnWizardDryRun');
    if (dryBtn) dryBtn.classList.add('hidden');

    if (state.step === 0) {
      const banner = state.isNewSet
        ? '<div class="banner">Adding a new backup set — existing sets stay intact.</div>'
        : '';
      body.innerHTML = banner +
        '<div class="grid">' +
        '<label class="field">Your name' + tip('Shown on HTML reports and optional emails.') +
        '<input id="fName" type="text" value="' + esc(f.operatorName) + '" /></label>' +
        '<label class="field">Name for this backup set' + tip('Friendly label in the console and Task Scheduler.') +
        '<input id="fDisplayName" type="text" value="' + esc(f.displayName) + '" /></label>' +
        '<label class="check"><input id="fConfirm" type="checkbox" ' + (f.confirmBackupPc ? 'checked' : '') + ' /> I confirm this is the Backup PC (destination), not the source machine</label></div>';
    } else if (state.step === 1) {
      body.innerHTML =
        '<div class="actions" style="margin-top:0">' +
        '<button type="button" class="btn soft" id="btnRefreshPrereq">Refresh checks</button>' +
        '<button type="button" class="btn primary" id="btnInstallRestic">Install restic</button>' +
        '<button type="button" class="btn soft" id="btnInstallRclone">Install rclone</button>' +
        '<button type="button" class="btn soft" id="btnInstallWinFspWizard">Install WinFsp</button>' +
        '</div>' +
        '<div class="status-line" id="prereqOut">Checking…</div>' +
        '<label class="field" style="margin-top:16px">restic path <span class="hint">(auto-filled when found or installed)</span>' +
        '<input id="fRestic" type="text" value="' + esc(f.resticPath) + '" /></label>' +
        '<p class="sub">Cloud destinations need rclone. Install it here, then add OneDrive/Google Drive from the destination step or Cloud settings (browser OAuth). Remotes are stored in <code>Config\\rclone.conf</code>.</p>' +
        '<p class="sub">WinFsp is optional — only needed to <strong>Mount</strong> the repository as a browsable folder. A Windows security prompt (UAC) appears during install.</p>';
      $('btnRefreshPrereq').onclick = refreshPrereqs;
      $('btnInstallRestic').onclick = installRestic;
      $('btnInstallRclone').onclick = installRclone;
      $('btnInstallWinFspWizard').onclick = installWinFsp;
      updateInstallResticBtn();
      updateInstallRcloneBtn();
      updateInstallWinFspBtn();
      refreshPrereqs();
    } else if (state.step === 2) {
      const nm = f.networkMode || 'both';
      body.innerHTML =
        '<div class="mode-row">' +
        '<label><input type="radio" name="fNetMode" value="lan" ' + (nm === 'lan' ? 'checked' : '') + ' /> Local LAN</label>' +
        '<label><input type="radio" name="fNetMode" value="tailscale" ' + (nm === 'tailscale' ? 'checked' : '') + ' /> Tailscale</label>' +
        '<label><input type="radio" name="fNetMode" value="both" ' + (nm === 'both' ? 'checked' : '') + ' /> Both</label>' +
        '</div>' +
        '<div class="grid two">' +
        '<label class="field">Source computer name' + tip('Hostname or Tailscale MagicDNS name used to build UNC paths.') +
        '<span class="hint">Tailscale MagicDNS name or LAN hostname</span><input id="fHost" type="text" value="' + esc(f.sourceHost) + '" placeholder="pc-name" /></label></div>' +
        '<label class="field">Source folders (UNC)' + tip('Paths this Backup PC can open. Admin shares like C$ work if your account has rights.') +
        '<span class="hint">Including admin $ shares, e.g. \\\\pc-name\\C$\\Users\\You\\Documents</span></label>' +
        '<div class="path-list" id="pathList"></div>' +
        '<div class="actions" style="margin-top:0"><button type="button" class="btn soft" id="btnAddPath">Add folder</button>' +
        '<button type="button" class="btn soft" id="btnTestConn">Test connectivity</button></div>' +
        '<div class="status-line" id="connOut"></div>' +
        '<label class="check"><input id="fShadow" type="checkbox" ' + (f.useShadowCopy !== false ? 'checked' : '') + ' /> Prefer Shadow Copies on the source (OfficeAgent) for open Office files</label>' +
        '<p class="sub">On the source PC, run scripts in the <code>OfficeAgent</code> folder (elevated). SyncMe can open that folder from Operations.</p>' +
        '<label class="check"><input id="fWol" type="checkbox" ' + (f.enableWakeOnLan ? 'checked' : '') + ' /> Send Wake-on-LAN before backup</label>' +
        '<label class="field">Source PC MAC address<span class="hint">AA:BB:CC:DD:EE:FF — BIOS/NIC WoL must be enabled</span>' +
        '<input id="fMac" type="text" value="' + esc(f.wakeMac || '') + '" /></label>';
      renderPathList();
      $('btnAddPath').onclick = () => {
        state.form.sourcePaths = collectPathList();
        state.form.sourcePaths.push('');
        renderPathList();
      };
      $('btnTestConn').onclick = testConn;
    } else if (state.step === 3) {
      const dt = f.destinationType || 'local';
      body.innerHTML =
        '<div class="mode-row">' +
        '<label><input type="radio" name="fDestType" value="local" ' + (dt === 'local' ? 'checked' : '') + ' /> Local folder</label>' +
        '<label><input type="radio" name="fDestType" value="nas" ' + (dt === 'nas' ? 'checked' : '') + ' /> NAS / network share</label>' +
        '<label><input type="radio" name="fDestType" value="rclone" ' + (dt === 'rclone' ? 'checked' : '') + ' /> Cloud (rclone)</label>' +
        '</div>' +
        '<div id="destLocalNas">' +
        '<div class="grid">' +
        '<label class="field">restic repository' + tip('Versioned restic repository folder. Prefer a dedicated subfolder, not a drive root.') +
        '<span class="hint">Full path on this Backup PC (your drive letter) or \\\\nas\\share\\repo</span>' +
        '<input id="fRepo" type="text" value="' + esc(f.resticRepo && f.resticRepo.indexOf('rclone:') === 0 ? '' : f.resticRepo) + '" placeholder="D:\\Backups\\repo" /></label>' +
        '<label class="check"><input id="fCreate" type="checkbox" ' + (f.createFolders ? 'checked' : '') + ' /> Create local/NAS folders if they do not exist</label></div>' +
        '</div>' +
        '<div id="destRclone" class="hidden">' +
        '<div class="grid two">' +
        '<label class="field">rclone remote<select id="fRcloneRemote"></select></label>' +
        '<label class="field">Folder on remote<input id="fRclonePath" type="text" value="' + esc(f.rcloneSubPath || '') + '" placeholder="SyncMe/set1" /></label>' +
        '<label class="field">Bandwidth limit<input id="fBwLimit" type="text" value="' + esc(f.rcloneBwLimit || 'off') + '" /></label>' +
        '<label class="field">Transfers<input id="fTransfers" type="number" value="' + esc(f.rcloneTransfers || 4) + '" /></label>' +
        '<label class="field">Retries<input id="fRetries" type="number" value="' + esc(f.rcloneRetries || 3) + '" /></label>' +
        '<label class="field">restic upload KiB/s<input id="fLimitUp" type="number" value="' + esc(f.resticLimitUploadKByte || 0) + '" /></label>' +
        '</div>' +
        '<div class="actions" style="margin-top:10px">' +
        '<button type="button" class="btn soft" id="btnWzRcloneRefresh">Refresh remotes</button>' +
        '<button type="button" class="btn primary" id="btnWzAddOd">Add OneDrive</button>' +
        '<button type="button" class="btn primary" id="btnWzAddGd">Add Google Drive</button>' +
        '<button type="button" class="btn soft" id="btnWzCancelOAuth">Cancel OAuth</button>' +
        '</div>' +
        '<div class="status-line" id="wzRcloneStatus"></div>' +
        '<p class="sub">OAuth runs in your browser (5-minute timeout). SyncMe writes remotes to <code>Config\\rclone.conf</code>.</p>' +
        '</div>';
      const syncDest = () => {
        const sel = document.querySelector('input[name="fDestType"]:checked');
        const isCloud = sel && sel.value === 'rclone';
        document.getElementById('destLocalNas').classList.toggle('hidden', !!isCloud);
        document.getElementById('destRclone').classList.toggle('hidden', !isCloud);
      };
      document.querySelectorAll('input[name="fDestType"]').forEach((r) => { r.onchange = syncDest; });
      syncDest();
      if (document.getElementById('btnWzRcloneRefresh')) {
        document.getElementById('btnWzRcloneRefresh').onclick = () => refreshRcloneRemotes('fRcloneRemote', 'wzRcloneStatus');
        document.getElementById('btnWzAddOd').onclick = () => startRcloneOAuth('onedrive', 'wzRcloneStatus', 'fRcloneRemote');
        document.getElementById('btnWzAddGd').onclick = () => startRcloneOAuth('drive', 'wzRcloneStatus', 'fRcloneRemote');
        document.getElementById('btnWzCancelOAuth').onclick = () => cancelRcloneOAuth('wzRcloneStatus');
        refreshRcloneRemotes('fRcloneRemote', 'wzRcloneStatus', f.rcloneRemote);
      }
    } else if (state.step === 4) {
      body.innerHTML =
        '<div class="field-stack">' +
        '<label class="field">restic password' + tip('Stored in Windows Credential Manager for this Windows account — never in Config.ps1.') +
        '<span class="hint">' + (state.isNewSet ? '' : 'Leave blank to keep the existing password') + '</span><input id="fRestPass" type="password" autocomplete="new-password" /></label>' +
        '<label class="field">Confirm restic password<input id="fRestPass2" type="password" autocomplete="new-password" /></label>' +
        '</div>' +
        '<label class="check"><input id="fStoreShare" type="checkbox" ' + (f.storeShare ? 'checked' : '') + ' /> Also store source share credentials</label>' +
        '<div class="field-stack" style="margin-top:8px">' +
        '<label class="field">Share username<input id="fShareUser" type="text" value="' + esc(f.shareUser) + '" /></label>' +
        '<label class="field">Share password<input id="fSharePass" type="password" autocomplete="new-password" /></label>' +
        '<label class="field">Confirm share password<input id="fSharePass2" type="password" autocomplete="new-password" /></label>' +
        '</div>';
    } else if (state.step === 5) {
      body.innerHTML =
        '<label class="check"><input id="fEmail" type="checkbox" ' + (f.enableEmail ? 'checked' : '') + ' /> Enable email notifications</label>' +
        '<div class="grid two">' +
        '<label class="field">SMTP server<input id="fSmtp" type="text" value="' + esc(f.smtpServer) + '" /></label>' +
        '<label class="field">Port<input id="fPort" type="text" value="' + esc(f.smtpPort) + '" /></label></div>' +
        '<label class="check"><input id="fSsl" type="checkbox" ' + (f.smtpSsl ? 'checked' : '') + ' /> Use SSL/TLS</label>' +
        '<div class="field-stack" style="max-width:none">' +
        '<div class="grid two">' +
        '<label class="field">From<input id="fFrom" type="email" value="' + esc(f.mailFrom) + '" /></label>' +
        '<label class="field">To (comma-separated)<input id="fTo" type="text" value="' + esc(f.mailTo) + '" /></label></div>' +
        '<label class="field">SMTP login<input id="fSmtpUser" type="text" value="' + esc(f.smtpUser) + '" /></label>' +
        '<label class="field">SMTP password<input id="fSmtpPass" type="password" autocomplete="new-password" /></label>' +
        '<label class="field">Confirm SMTP password<input id="fSmtpPass2" type="password" autocomplete="new-password" /></label></div>';
    } else if (state.step === 6) {
      const days = f.scheduleDaysOfWeek && f.scheduleDaysOfWeek.length ? f.scheduleDaysOfWeek : WEEKDAYS;
      const dayChecks = WEEKDAYS.map((d) =>
        '<label><input type="checkbox" id="fDay' + d + '" ' + (days.indexOf(d) >= 0 ? 'checked' : '') + ' /> ' + d.slice(0, 3) + '</label>'
      ).join('');
      const rec = f.scheduleRecurrence || 'Daily';
      body.innerHTML =
        '<div class="grid two">' +
        '<label class="field">Start date<input id="fStartDate" type="date" value="' + esc(f.scheduleStartDate || '') + '" /></label>' +
        '<label class="field">Time (HH:mm)<input id="fTime" type="text" value="' + esc(f.runTime) + '" placeholder="01:00" /></label>' +
        '<label class="field">Recurrence<select id="fRecurrence">' +
        '<option value="Once"' + (rec === 'Once' ? ' selected' : '') + '>Once</option>' +
        '<option value="Daily"' + (rec === 'Daily' ? ' selected' : '') + '>Daily</option>' +
        '<option value="Weekly"' + (rec === 'Weekly' ? ' selected' : '') + '>Weekly</option>' +
        '</select></label>' +
        '<label class="field" id="schedEndWrap">End date<span class="hint">Optional — leave blank for no end</span>' +
        '<input id="fEndDate" type="date" value="' + esc(f.scheduleEndDate || '') + '" /></label>' +
        '</div>' +
        '<div id="schedDaysWrap"><label class="field">Days of week</label><div class="day-checks">' + dayChecks + '</div></div>' +
        '<label class="check"><input id="fUnattended" type="checkbox" ' + (f.taskLogonType !== 'Interactive' ? 'checked' : '') + ' /> Run whether logged on or not (recommended for Windows Server)' + tip('Required on Windows Server so backups run after reboot without an interactive session. Password goes to Task Scheduler only.') + '</label>' +
        '<p class="sub">Unattended tasks need this Windows account password stored in Task Scheduler. Use the same account that holds SyncMe Credential Manager secrets (restic / share / SMTP).</p>' +
        '<div class="grid two" id="winPassWrap">' +
        '<label class="field">Windows account password' + tip('Same Windows user that owns Credential Manager entries for SyncMe.') +
        '<input id="fWinPass" type="password" autocomplete="current-password" /></label>' +
        '<label class="field">Confirm Windows password<input id="fWinPass2" type="password" autocomplete="current-password" /></label>' +
        '</div>' +
        '<label class="check"><input id="fToast" type="checkbox" ' + (f.enableToast ? 'checked' : '') + ' /> Enable Windows toast notifications</label>' +
        '<p class="sub">Scheduled tasks run with the SyncMe console closed. Console is only at http://127.0.0.1 — use RDP on Server.</p>';
      const recEl = document.getElementById('fRecurrence');
      if (recEl) recEl.onchange = syncScheduleFieldsVisibility;
      const unEl = document.getElementById('fUnattended');
      if (unEl) {
        unEl.onchange = function () {
          const wrap = document.getElementById('winPassWrap');
          if (wrap) wrap.style.display = unEl.checked ? '' : 'none';
        };
        unEl.onchange();
      }
      syncScheduleFieldsVisibility();
    } else if (state.step === 7) {
      body.innerHTML =
        '<div class="status-line">' +
        'Set: ' + esc(f.displayName) + '<br/>' +
        'Operator: ' + esc(f.operatorName || 'friend') + '<br/>' +
        'Network: ' + esc(f.networkMode) + '<br/>' +
        'Source: ' + esc(f.sourceHost) + ' — ' + esc((f.sourcePaths || []).join(', ')) + '<br/>' +
        'Destination: ' + esc(f.destinationType) + ' — ' + esc(f.resticRepo) + '<br/>' +
        'Email: ' + (f.enableEmail ? 'yes (' + esc(f.smtpServer) + ')' : 'no') + '<br/>' +
        'Task logon: ' + (f.taskLogonType === 'Interactive' ? 'while logged on' : 'whether logged on or not') + '<br/>' +
        'Schedule: ' + esc(scheduleSummary(f)) + ' → Task Scheduler' +
        '</div>';
    }
  }

  function esc(s) {
    return String(s == null ? '' : s)
      .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/"/g, '&quot;');
  }

  function updateInstallResticBtn() {
    const btn = document.getElementById('btnInstallRestic');
    if (!btn) return;
    btn.disabled = !!state.resticOk;
    btn.textContent = state.resticOk ? 'restic installed' : 'Install restic';
    btn.classList.toggle('installed', !!state.resticOk);
    btn.classList.toggle('primary', !state.resticOk);
  }

  function updateInstallRcloneBtn() {
    const btn = document.getElementById('btnInstallRclone');
    if (!btn) return;
    btn.disabled = !!state.rcloneOk;
    btn.textContent = state.rcloneOk ? 'rclone installed' : 'Install rclone';
    btn.classList.toggle('installed', !!state.rcloneOk);
    btn.classList.toggle('soft', !state.rcloneOk);
  }

  function updateInstallWinFspBtn() {
    const btn = document.getElementById('btnInstallWinFspWizard');
    if (!btn) return;
    btn.disabled = !!state.winfspOk;
    btn.textContent = state.winfspOk ? 'WinFsp installed' : 'Install WinFsp';
    btn.classList.toggle('installed', !!state.winfspOk);
    btn.classList.toggle('soft', !state.winfspOk);
  }

  async function refreshPrereqs() {
    try {
      const d = await api('/api/prereqs');
      const lines = [];
      lines.push(d.tailscaleOk ? ('Tailscale: OK — ' + d.tailscaleMessage) : ('Tailscale: WARN — ' + d.tailscaleMessage + ' (OK to ignore on LAN-only)'));
      if (d.tailscaleMessage && /LAN-only|Skipped/i.test(String(d.tailscaleMessage))) {
        lines[lines.length - 1] = 'Tailscale: skipped (LAN-only network mode)';
      }
      lines.push(d.resticOk ? ('restic: found at ' + d.resticPath) : 'restic: NOT found — click Install restic');
      lines.push(d.rcloneOk ? ('rclone: found at ' + d.rclonePath) : 'rclone: not found (optional — needed for OneDrive/Google Drive)');
      lines.push(d.winfspOk ? 'WinFsp: OK (needed for Mount)' : 'WinFsp: not found (optional — click Install WinFsp to browse mounts)');
      state.resticOk = !!d.resticOk;
      state.rcloneOk = !!d.rcloneOk;
      state.winfspOk = !!d.winfspOk;
      if (d.resticOk && d.resticPath) {
        const el = document.getElementById('fRestic');
        if (el) el.value = d.resticPath;
        state.form.resticPath = d.resticPath;
      }
      updateInstallResticBtn();
      updateInstallRcloneBtn();
      updateInstallWinFspBtn();
      setStatus($('prereqOut'), lines.join('\n'), d.resticOk ? 'ok' : 'warn');
    } catch (e) {
      state.resticOk = false;
      state.rcloneOk = false;
      state.winfspOk = false;
      updateInstallResticBtn();
      updateInstallRcloneBtn();
      updateInstallWinFspBtn();
      setStatus($('prereqOut'), e.message, 'err');
    }
  }

  async function installRclone() {
    setStatus($('prereqOut'), 'Downloading rclone from GitHub…', 'busy');
    try {
      const d = await api('/api/prereqs/install-rclone', { method: 'POST', body: '{}' });
      state.rcloneOk = !!d.rcloneOk;
      updateInstallRcloneBtn();
      setStatus($('prereqOut'), d.message || 'rclone installed.', d.rcloneOk ? 'ok' : 'warn');
    } catch (e) {
      setStatus($('prereqOut'), e.message, 'err');
    }
  }

  async function installWinFsp() {
    const btn = document.getElementById('btnInstallWinFspWizard');
    if (btn) btn.disabled = true;
    setStatus($('prereqOut'), 'Downloading WinFsp installer… Approve the Windows security prompt if asked.', 'busy');
    try {
      const d = await api('/api/prereqs/install-winfsp', { method: 'POST', body: '{}' });
      state.winfspOk = !!d.winfspOk;
      updateInstallWinFspBtn();
      setStatus($('prereqOut'), d.message || 'WinFsp installed.', d.winfspOk ? 'ok' : 'warn');
      if ($('mountStatus')) refreshMountStatus();
    } catch (e) {
      state.winfspOk = false;
      updateInstallWinFspBtn();
      setStatus($('prereqOut'), e.message, 'err');
    }
  }

  async function installRestic() {
    const btn = document.getElementById('btnInstallRestic');
    if (btn) btn.disabled = true;
    setStatus($('prereqOut'), 'Downloading restic from GitHub…', '');
    try {
      const d = await api('/api/prereqs/install-restic', { method: 'POST', body: '{}' });
      state.resticOk = !!d.resticOk;
      if (d.resticPath) {
        const el = document.getElementById('fRestic');
        if (el) el.value = d.resticPath;
        state.form.resticPath = d.resticPath;
      }
      updateInstallResticBtn();
      setStatus($('prereqOut'), d.message || ('restic ready at ' + d.resticPath), d.resticOk ? 'ok' : 'warn');
    } catch (e) {
      state.resticOk = false;
      updateInstallResticBtn();
      setStatus($('prereqOut'), e.message, 'err');
    }
  }

  async function testConn() {
    collectForm();
    const btn = document.getElementById('btnTestConn');
    if (btn) btn.disabled = true;
    setStatus($('connOut'), 'Testing connectivity to ' + (state.form.sourceHost || 'host') + '…\nThis can take a few seconds.', 'busy');
    try {
      const d = await api('/api/test-source', {
        method: 'POST',
        body: JSON.stringify({ host: state.form.sourceHost, paths: (state.form.sourcePaths || []).join('\n') })
      });
      setStatus($('connOut'), (d.messages || []).join('\n'), d.allOk ? 'ok' : 'warn');
    } catch (e) {
      setStatus($('connOut'), e.message, 'err');
    } finally {
      if (btn) btn.disabled = false;
    }
  }

  function validateStep() {
    collectForm();
    const f = state.form;
    if (state.step === 0) {
      if (!f.confirmBackupPc) return 'Please confirm this is the Backup PC.';
      if (!f.displayName) return 'Name this backup set.';
    }
    if (state.step === 1) {
      if (!state.resticOk) return 'Install restic first (or Refresh checks once it is available).';
    }
    if (state.step === 2) {
      if (!f.sourceHost) return 'Enter source host name (Tailscale MagicDNS or LAN hostname).';
      if (!f.sourcePaths || !f.sourcePaths.length) return 'Add at least one UNC source folder.';
      const bad = (f.sourcePaths || []).find((p) => !/^\\\\[^\\]+\\[^\\]+/.test(String(p).trim()));
      if (bad) return 'Each source must be a UNC path, including $ shares (e.g. \\\\pc-name\\C$\\Users\\You).';
    }
    if (state.step === 3) {
      if (f.destinationType === 'rclone') {
        if (!f.rcloneRemote && (!f.resticRepo || String(f.resticRepo).indexOf('rclone:') !== 0)) {
          return 'Select or add an rclone remote for cloud destination.';
        }
      } else {
        const repo = String(f.resticRepo || '').trim();
        if (!repo) return 'Enter restic repository destination (full path on this Backup PC).';
        if (!/^[A-Za-z]:\\/.test(repo) && !/^\\\\[^\\]+\\[^\\]+/.test(repo)) {
          return 'Repository must be a full path (e.g. D:\\Backups\\repo) or UNC. Relative paths are not allowed.';
        }
      }
    }
    if (state.step === 4) {
      if (state.isNewSet || f.resticPassword || f.resticPassword2) {
        if (!f.resticPassword || f.resticPassword !== f.resticPassword2) return 'restic passwords are empty or do not match.';
      }
      if (f.storeShare) {
        if (!f.shareUser) return 'Enter share username.';
        if (!f.sharePassword || f.sharePassword !== f.sharePassword2) return 'Share passwords are empty or do not match.';
      }
      if (f.enableWakeOnLan && f.wakeMac && !/^[0-9A-Fa-f:-]{12,17}$/.test(f.wakeMac.replace(/\s/g, ''))) {
        return 'Wake-on-LAN MAC looks invalid.';
      }
    }
    if (state.step === 5 && f.enableEmail) {
      if (!f.mailFrom || f.mailFrom.indexOf('@') < 0) return 'Enter a valid From address.';
      if (!f.smtpPassword || f.smtpPassword !== f.smtpPassword2) return 'SMTP passwords are empty or do not match.';
    }
    if (state.step === 6) {
      if (!/^\d{1,2}:\d{2}$/.test(f.runTime)) return 'Use time format HH:mm (e.g. 01:00).';
      if (!f.scheduleStartDate || !/^\d{4}-\d{2}-\d{2}$/.test(f.scheduleStartDate)) return 'Enter a start date.';
      if (f.scheduleRecurrence === 'Weekly' && (!f.scheduleDaysOfWeek || !f.scheduleDaysOfWeek.length)) {
        return 'Select at least one day of the week.';
      }
      if (f.scheduleEndDate && f.scheduleStartDate && f.scheduleEndDate < f.scheduleStartDate) {
        return 'End date must be on or after the start date.';
      }
      if (f.taskLogonType !== 'Interactive') {
        if (!f.windowsPassword || f.windowsPassword !== f.windowsPassword2) {
          return 'Windows account passwords are empty or do not match (needed for unattended Task Scheduler).';
        }
      }
    }
    return null;
  }

  async function applySetup() {
    collectForm();
    setStatus($('setupStatus'), 'Applying configuration…', 'busy');
    $('btnNext').disabled = true;
    try {
      const payload = Object.assign({}, state.form, {
        sourcePaths: (state.form.sourcePaths || []).join('\n'),
        isNewSet: !!state.isNewSet,
        setId: state.isNewSet ? '' : (state.form.setId || state.activeSetId || ''),
        scheduleDaysOfWeek: state.form.scheduleDaysOfWeek || WEEKDAYS.slice(),
        logonType: state.form.taskLogonType || 'Password',
        windowsPassword: state.form.windowsPassword || ''
      });
      delete payload.windowsPassword2;
      delete payload.taskLogonType;
      const d = await api('/api/setup/apply', { method: 'POST', body: JSON.stringify(payload) });
      setStatus($('setupStatus'), (d.message || 'Setup complete.') + '\n\nOptional: run a dry run to verify the backup works.', 'ok');
      setTop('Configured', 'ok');
      state.isNewSet = false;
      if (d.setId) state.activeSetId = d.setId;
      else if (state.form.setId) state.activeSetId = state.form.setId;
      state.setupAppliedSetId = state.activeSetId;
      const dryBtn = $('btnWizardDryRun');
      if (dryBtn) dryBtn.classList.remove('hidden');
      await loadDash();
    } catch (e) {
      setStatus($('setupStatus'), e.message, 'err');
    } finally {
      $('btnNext').disabled = false;
    }
  }

  async function wizardDryRun() {
    const setId = state.setupAppliedSetId || state.activeSetId || 'set1';
    setStatus($('setupStatus'), 'Starting dry run…', 'busy');
    try {
      await api('/api/backup', {
        method: 'POST',
        body: JSON.stringify({ mode: 'whatIf', setId: setId })
      });
      pollWizardDryRun();
    } catch (e) {
      setStatus($('setupStatus'), e.message, 'err');
    }
  }

  async function pollWizardDryRun() {
    try {
      const d = await api('/api/backup/status');
      if (d.running) {
        setStatus($('setupStatus'), 'Dry run running… ' + (d.detail || d.message || ''), 'busy');
        setTimeout(pollWizardDryRun, 2000);
      } else if (d.finished) {
        setStatus($('setupStatus'), d.message || ('Dry run finished (exit ' + d.exitCode + ').'), d.exitCode === 0 ? 'ok' : 'warn');
        show('view-dash');
        await loadDash();
      } else {
        setTimeout(pollWizardDryRun, 1500);
      }
    } catch (e) {
      setStatus($('setupStatus'), e.message, 'err');
    }
  }

  function renderSetSwitcher(sets, activeId) {
    const el = $('setSwitcher');
    if (!el) return;
    if (!sets || sets.length < 2) {
      el.innerHTML = '';
      return;
    }
    el.innerHTML = sets.map((s) =>
      '<button type="button" class="set-pill' + (s.id === activeId ? ' active' : '') + '" data-set="' + esc(s.id) + '">' +
      esc(s.displayName || s.id) + '</button>'
    ).join('');
    el.querySelectorAll('.set-pill').forEach((b) => {
      b.onclick = () => {
        state.activeSetId = b.getAttribute('data-set');
        loadDash();
        const ops = $('view-ops');
        if (ops && !ops.classList.contains('hidden')) refreshSnaps();
      };
    });
  }

  function renderSetList(sets, activeId) {
    const el = $('setList');
    if (!el) return;
    if (!sets || !sets.length) {
      el.innerHTML = '<div class="muted">No backup sets yet. Use Add set or the Setup wizard.</div>';
      return;
    }
    el.innerHTML = sets.map((s) => {
      const sched = (s.scheduleRecurrence || 'Daily') + ' at ' + (s.runTime || '01:00');
      return '<div class="set-row' + (s.id === activeId ? ' active' : '') + '" data-set="' + esc(s.id) + '">' +
        '<div class="set-row-meta">' +
        '<div class="name">' + esc(s.displayName || s.id) + '</div>' +
        '<div class="detail">' + esc(s.destinationType || 'local') + ' · ' + esc(sched) +
        (s.scheduleStartDate ? (' · from ' + esc(s.scheduleStartDate)) : '') +
        (s.scheduleEndDate ? (' · until ' + esc(s.scheduleEndDate)) : '') +
        '</div></div>' +
        '<div class="set-row-actions">' +
        '<button type="button" class="btn soft btn-select-set" data-set="' + esc(s.id) + '">Select</button>' +
        '<button type="button" class="btn ghost btn-edit-set" data-set="' + esc(s.id) + '">Edit</button>' +
        '<button type="button" class="btn ghost btn-delete-set" data-set="' + esc(s.id) + '">Delete</button>' +
        '</div></div>';
    }).join('');
    el.querySelectorAll('.btn-select-set').forEach((b) => {
      b.onclick = () => {
        state.activeSetId = b.getAttribute('data-set');
        loadDash();
        refreshSnaps();
      };
    });
    el.querySelectorAll('.btn-edit-set').forEach((b) => {
      b.onclick = () => openEditSet(b.getAttribute('data-set'));
    });
    el.querySelectorAll('.btn-delete-set').forEach((b) => {
      b.onclick = () => deleteSet(b.getAttribute('data-set'));
    });
    el.querySelectorAll('.set-row').forEach((row) => {
      row.onclick = (e) => {
        if (e.target.closest('button')) return;
        state.activeSetId = row.getAttribute('data-set');
        loadDash();
        refreshSnaps();
      };
    });
  }

  function renderLastRun(lr) {
    const body = $('lastRunBody');
    if (!body) return;
    if (!lr) {
      body.innerHTML = '<div class="muted">No run details yet.</div>';
      return;
    }
    const ok = lr.success !== false;
    const warnList = Array.isArray(lr.warnings) ? lr.warnings : [];
    let html = '<div class="last-run-grid">' +
      '<div class="last-run-stat"><div class="k">Status</div><div class="v">' + (ok ? 'OK' : 'Issues') + '</div></div>' +
      '<div class="last-run-stat"><div class="k">Ended</div><div class="v">' + esc(lr.endTime || '—') + '</div></div>' +
      '<div class="last-run-stat"><div class="k">Files new</div><div class="v">' + esc(lr.filesNew || '—') + '</div></div>' +
      '<div class="last-run-stat"><div class="k">Changed</div><div class="v">' + esc(lr.filesChanged || '—') + '</div></div>' +
      '<div class="last-run-stat"><div class="k">Unmodified</div><div class="v">' + esc(lr.filesUnmodified || '—') + '</div></div>' +
      '<div class="last-run-stat"><div class="k">Data added</div><div class="v">' + esc(lr.dataAdded || '—') + '</div></div>' +
      '<div class="last-run-stat"><div class="k">Snapshot</div><div class="v">' + esc((lr.snapshotId || '—').toString().slice(0, 12)) + '</div></div>' +
      '<div class="last-run-stat"><div class="k">Exit</div><div class="v">' + esc(lr.backupExitCode || '—') + '</div></div>' +
      '</div>';
    if (lr.summary) html += '<div class="prog-meta" style="margin-top:10px">' + esc(lr.summary) + '</div>';
    if (lr.backupExitCode === '3' || (lr.openFileRisk && lr.openFileRisk !== '')) {
      html += '<p class="sub" style="margin-top:10px;color:var(--warn)">Some files may have been skipped (restic exit 3 / open-file risk). Prefer Shadow Copies via OfficeAgent.</p>';
    }
    if (warnList.length) {
      html += '<ul class="last-run-warnings">' + warnList.slice(0, 8).map((w) => '<li>' + esc(w) + '</li>').join('') + '</ul>';
    }
    body.innerHTML = html;
  }

  function tip(text) {
    return '<button type="button" class="tip" data-tip="' + esc(text) + '" aria-label="Help" tabindex="0">?</button>';
  }

  function formatEtaSeconds(sec) {
    if (sec == null || !isFinite(sec) || sec < 0) return '';
    if (sec < 60) return '~' + Math.max(1, Math.round(sec)) + 's remaining';
    if (sec < 3600) return '~' + Math.round(sec / 60) + 'm remaining';
    const h = Math.floor(sec / 3600);
    const m = Math.round((sec % 3600) / 60);
    return '~' + h + 'h ' + m + 'm remaining';
  }

  function computeEta(d) {
    const etaEl = $('progEta');
    if (!etaEl) return;
    if (!d.running) {
      state.etaSamples = [];
      etaEl.textContent = '';
      return;
    }
    const mode = d.progressMode || '';
    const scanning = mode === 'scanning' || d.percent == null;
    const bytesDone = d.bytesDone != null ? Number(d.bytesDone) : null;
    const totalBytes = d.totalBytes != null ? Number(d.totalBytes) : null;
    if (scanning || bytesDone == null || totalBytes == null || totalBytes <= 0 || bytesDone <= 0) {
      etaEl.textContent = '· Estimating…';
      return;
    }
    const now = Date.now();
    state.etaSamples.push({ t: now, b: bytesDone });
    if (state.etaSamples.length > 12) state.etaSamples.shift();
    if (state.etaSamples.length < 2) {
      etaEl.textContent = '· Estimating…';
      return;
    }
    const first = state.etaSamples[0];
    const last = state.etaSamples[state.etaSamples.length - 1];
    const dt = (last.t - first.t) / 1000;
    const db = last.b - first.b;
    if (dt < 2 || db <= 0) {
      etaEl.textContent = '· Estimating…';
      return;
    }
    const rate = db / dt;
    const remain = (totalBytes - bytesDone) / rate;
    etaEl.textContent = '· ' + formatEtaSeconds(remain);
  }

  function updateProgressUI(d) {
    const phase = $('progPhase');
    const bar = $('progBar');
    const fill = $('progFill');
    const meta = $('progMeta');
    if (!phase) return;
    if (d.running) {
      const mode = d.progressMode || '';
      const scanning = mode === 'scanning' || d.percent == null;
      phase.textContent = (d.phase ? (d.phase + ' — ') : '') + (d.message || (scanning ? 'Scanning source…' : 'Backup running…'));
      if (scanning) {
        bar.classList.add('indet');
        fill.style.width = '35%';
        if (meta) meta.textContent = d.detail || 'Scanning source… totals grow as folders are discovered';
      } else {
        bar.classList.remove('indet');
        fill.style.width = Math.max(0, Math.min(100, d.percent)) + '%';
        if (meta) meta.textContent = d.detail || (d.percent + '%');
      }
      computeEta(d);
    } else if (d.finished) {
      bar.classList.remove('indet');
      fill.style.width = d.exitCode === 0 ? '100%' : '0%';
      phase.textContent = d.message || 'Finished';
      if (meta) meta.textContent = d.detail || '';
      computeEta({ running: false });
    } else {
      bar.classList.remove('indet');
      fill.style.width = '0%';
      phase.textContent = 'No backup running';
      if (meta) meta.textContent = 'Idle — scheduled jobs still run via Task Scheduler';
      computeEta({ running: false });
    }
  }

  function diskLabel(freeGb, pct) {
    if (freeGb == null) return '—';
    let s = freeGb + ' GB';
    if (pct != null) s += ' (' + pct + '%)';
    return s;
  }

  function formatLastSuccess(raw) {
    if (!raw) return '(none yet)';
    const s = String(raw).trim();
    if (!s || s === '(none yet)') return '(none yet)';
    const d = new Date(s);
    if (Number.isNaN(d.getTime())) return s;
    const pad = (n) => String(n).padStart(2, '0');
    return d.getFullYear() + '-' + pad(d.getMonth() + 1) + '-' + pad(d.getDate())
      + ' ' + pad(d.getHours()) + ':' + pad(d.getMinutes());
  }

  async function loadDash() {
    const q = state.activeSetId ? ('?setId=' + encodeURIComponent(state.activeSetId)) : '';
    const d = await api('/api/status' + q);
    state.sets = d.sets || [];
    if (d.activeSetId && (!state.activeSetId || state.sets.every(s => s.id !== state.activeSetId))) {
      state.activeSetId = d.activeSetId;
    }
    renderSetSwitcher(state.sets, state.activeSetId);
    renderSetList(state.sets, state.activeSetId);

    $('statLast').textContent = formatLastSuccess(d.lastSuccess);
    const net = d.networkMode || 'both';
    $('statTs').textContent = net === 'lan' ? 'LAN' : (d.tailscaleOk ? 'OK' : 'WARN');
    setStatCard('statNetCard', net === 'lan' ? 'ok' : (d.tailscaleOk ? 'ok' : 'warn'));

    state.resticOk = !!d.resticOk;
    state.rcloneOk = !!d.rcloneOk;
    $('statRestic').textContent = d.resticOk ? 'Ready' : 'Missing';
    setStatCard('statResticCard', d.resticOk ? 'ok' : 'danger');
    if ($('statRclone')) {
      $('statRclone').textContent = d.rcloneOk ? 'Ready' : 'Missing';
      setStatCard('statRcloneCard', d.rcloneOk ? 'ok' : 'danger');
    }

    if ($('statDisk1')) $('statDisk1').textContent = diskLabel(d.disk1FreeGb, d.disk1PercentFree);
    const d1warn = d.disk1PercentFree != null && d.disk1PercentFree < 15;
    setStatCard('statDisk1Card', d1warn ? 'warn' : '');
    if ($('statDisk2Card')) $('statDisk2Card').classList.add('hidden');
    const destCloud = (d.resticRepo || '').indexOf('rclone:') === 0;
    if ($('statRcloneCard')) $('statRcloneCard').classList.toggle('hidden', !destCloud && !d.rcloneOk);
    const lowChip = $('lowDiskChip');
    if (lowChip) lowChip.classList.toggle('hidden', !(d.lowDisk || d1warn));

    renderLastRun(d.lastRun);

    const overview = $('setOverviewBody');
    if (overview) {
      const active = (state.sets || []).find((s) => s.id === state.activeSetId) || {};
      overview.innerHTML =
        '<div class="prog-meta">' +
        esc(active.displayName || state.activeSetId || '—') + ' · ' +
        esc(scheduleSummary({
          runTime: d.runTime,
          scheduleStartDate: d.scheduleStartDate,
          scheduleRecurrence: d.scheduleRecurrence,
          scheduleEndDate: d.scheduleEndDate,
          scheduleDaysOfWeek: d.scheduleDaysOfWeek
        })) + '<br/>' +
        'Repo: ' + esc(d.resticRepo || '—') +
        '</div>';
    }

    setTop(d.configured ? 'Ready' : 'Needs setup', d.configured ? 'ok' : 'warn');
    setStatus($('dashStatus'), d.backupRunning ? 'A backup appears to be running.' : 'Ready.', d.backupRunning ? 'warn' : '');
    if (d.defaultRestoreTarget && $('restoreTarget')) $('restoreTarget').value = d.defaultRestoreTarget;
    await fillDashPolicyAndCloud();
    refreshMountStatus();
    if (d.backupRunning) pollBackup();
    else {
      try { updateProgressUI(await api('/api/backup/status')); } catch (e) { /* ignore */ }
    }
  }

  async function fillDashPolicyAndCloud() {
    try {
      const d = await api('/api/set?setId=' + encodeURIComponent(state.activeSetId || 'set1'));
      if ($('polKeepLast')) $('polKeepLast').value = d.keepLast != null ? d.keepLast : 7;
      if ($('polKeepDaily')) $('polKeepDaily').value = d.keepDaily != null ? d.keepDaily : 14;
      if ($('polKeepWeekly')) $('polKeepWeekly').value = d.keepWeekly != null ? d.keepWeekly : 8;
      if ($('polKeepMonthly')) $('polKeepMonthly').value = d.keepMonthly != null ? d.keepMonthly : 6;
      if ($('polEnableCheck')) $('polEnableCheck').checked = d.enableRepoCheck !== false;
      if ($('polCheckDay') && d.weeklyDataCheckDay) $('polCheckDay').value = d.weeklyDataCheckDay;
      if ($('rcloneBwLimit')) $('rcloneBwLimit').value = d.rcloneBwLimit || 'off';
      if ($('resticLimitUpload')) $('resticLimitUpload').value = d.resticLimitUploadKByte != null ? d.resticLimitUploadKByte : 0;
      if ($('rcloneTransfers')) $('rcloneTransfers').value = d.rcloneTransfers != null ? d.rcloneTransfers : 4;
      if ($('rcloneCheckers')) $('rcloneCheckers').value = d.rcloneCheckers != null ? d.rcloneCheckers : 8;
      if ($('rcloneRetries')) $('rcloneRetries').value = d.rcloneRetries != null ? d.rcloneRetries : 3;
      if ($('rcloneLowRetries')) $('rcloneLowRetries').value = d.rcloneLowLevelRetries != null ? d.rcloneLowLevelRetries : 10;
      if ($('rcloneSubPath')) $('rcloneSubPath').value = d.rcloneSubPath || '';
      await refreshRcloneRemotes('rcloneRemote', 'rcloneStatus', d.rcloneRemote || '');
    } catch (e) {
      if ($('rcloneStatus')) setStatus($('rcloneStatus'), e.message, 'warn');
    }
  }

  async function refreshRcloneRemotes(selectId, statusId, prefer) {
    const sel = document.getElementById(selectId);
    const st = document.getElementById(statusId);
    if (!sel) return;
    try {
      if (st) setStatus(st, 'Loading remotes…', 'busy');
      const d = await api('/api/rclone/status');
      sel.innerHTML = '';
      const remotes = d.remotes || [];
      if (!remotes.length) {
        sel.innerHTML = '<option value="">(no remotes yet)</option>';
      } else {
        remotes.forEach((r) => {
          const o = document.createElement('option');
          o.value = r;
          o.textContent = r;
          if (prefer && prefer === r) o.selected = true;
          sel.appendChild(o);
        });
      }
      if (st) {
        setStatus(st, d.rcloneOk
          ? ('rclone OK — ' + (d.configPath || '') + (remotes.length ? (' · ' + remotes.length + ' remote(s)') : ' · add OneDrive/Google Drive'))
          : 'rclone not installed — use Prerequisites',
          d.rcloneOk ? 'ok' : 'warn');
      }
    } catch (e) {
      if (st) setStatus(st, e.message, 'err');
    }
  }

  async function startRcloneOAuth(type, statusId, selectId) {
    const st = document.getElementById(statusId);
    const name = prompt('Name for this ' + (type === 'drive' ? 'Google Drive' : 'OneDrive') + ' remote:', type === 'drive' ? 'gdrive' : 'onedrive');
    if (!name) return;
    try {
      if (st) setStatus(st, 'Starting OAuth…', 'busy');
      await api('/api/rclone/authorize', {
        method: 'POST',
        body: JSON.stringify({ type: type, name: name.trim() })
      });
      pollRcloneOAuth(statusId, selectId);
    } catch (e) {
      if (st) setStatus(st, e.message, 'err');
    }
  }

  async function cancelRcloneOAuth(statusId) {
    const st = document.getElementById(statusId);
    try {
      if (state.pollTimerOauth) {
        clearTimeout(state.pollTimerOauth);
        state.pollTimerOauth = null;
      }
      const d = await api('/api/rclone/authorize/cancel', { method: 'POST', body: '{}' });
      state._oauthOpened = null;
      if (st) setStatus(st, d.message || 'OAuth cancelled.', 'warn');
    } catch (e) {
      if (st) setStatus(st, e.message, 'err');
    }
  }

  async function pollRcloneOAuth(statusId, selectId) {
    const st = document.getElementById(statusId);
    try {
      const d = await api('/api/rclone/authorize');
      if (d.url && st) {
        setStatus(st, 'Authorize in browser (times out after 5 min):\n' + d.url + '\n\nWaiting for completion…', 'busy');
        if (!state._oauthOpened || state._oauthOpened !== d.url) {
          state._oauthOpened = d.url;
          try { window.open(d.url, '_blank'); } catch (e) { /* ignore */ }
        }
      } else if (st && d.message) {
        setStatus(st, d.message, d.running ? 'busy' : (d.success ? 'ok' : 'warn'));
      }
      if (d.running) {
        state.pollTimerOauth = setTimeout(() => pollRcloneOAuth(statusId, selectId), 1500);
      } else if (d.finished) {
        state._oauthOpened = null;
        if (d.success) {
          await refreshRcloneRemotes(selectId, statusId, d.name);
          if (st) setStatus(st, d.message || ('Remote ' + d.name + ' ready.'), 'ok');
        } else if (st) {
          setStatus(st, d.message || 'OAuth failed.', 'err');
        }
      }
    } catch (e) {
      if (st) setStatus(st, e.message, 'err');
    }
  }

  async function saveRcloneCloud() {
    const remote = ($('rcloneRemote') && $('rcloneRemote').value) || '';
    if (!remote) {
      setStatus($('rcloneStatus'), 'Select or add a remote first.', 'warn');
      return;
    }
    setStatus($('rcloneStatus'), 'Saving cloud destination…', 'busy');
    try {
      const d = await api('/api/set/rclone', {
        method: 'POST',
        body: JSON.stringify({
          setId: state.activeSetId || 'set1',
          remote: remote,
          path: ($('rcloneSubPath') && $('rcloneSubPath').value) || '',
          rcloneBwLimit: ($('rcloneBwLimit') && $('rcloneBwLimit').value) || 'off',
          rcloneTransfers: parseInt(($('rcloneTransfers') && $('rcloneTransfers').value) || '4', 10),
          rcloneCheckers: parseInt(($('rcloneCheckers') && $('rcloneCheckers').value) || '8', 10),
          rcloneRetries: parseInt(($('rcloneRetries') && $('rcloneRetries').value) || '3', 10),
          rcloneLowLevelRetries: parseInt(($('rcloneLowRetries') && $('rcloneLowRetries').value) || '10', 10),
          resticLimitUploadKByte: parseInt(($('resticLimitUpload') && $('resticLimitUpload').value) || '0', 10)
        })
      });
      setStatus($('rcloneStatus'), d.message || 'Saved.', 'ok');
      await loadDash();
    } catch (e) {
      setStatus($('rcloneStatus'), e.message, 'err');
    }
  }

  async function testRcloneCloud() {
    const remote = ($('rcloneRemote') && $('rcloneRemote').value) || '';
    if (!remote) {
      setStatus($('rcloneStatus'), 'Select a remote first.', 'warn');
      return;
    }
    const sub = (($('rcloneSubPath') && $('rcloneSubPath').value) || '').replace(/^\/+/, '');
    const path = sub ? (remote + ':' + sub) : (remote + ':');
    setStatus($('rcloneStatus'), 'Testing ' + path + '…', 'busy');
    try {
      const d = await api('/api/rclone/test', { method: 'POST', body: JSON.stringify({ path: path }) });
      setStatus($('rcloneStatus'), d.message || 'OK', 'ok');
    } catch (e) {
      setStatus($('rcloneStatus'), e.message, 'err');
    }
  }

  async function savePolicy() {
    setStatus($('dashStatus'), 'Saving retention policy…', 'busy');
    try {
      const d = await api('/api/set/policy', {
        method: 'POST',
        body: JSON.stringify({
          setId: state.activeSetId || 'set1',
          keepLast: parseInt($('polKeepLast').value, 10),
          keepDaily: parseInt($('polKeepDaily').value, 10),
          keepWeekly: parseInt($('polKeepWeekly').value, 10),
          keepMonthly: parseInt($('polKeepMonthly').value, 10),
          enableRepoCheck: $('polEnableCheck').checked,
          weeklyDataCheckDay: $('polCheckDay').value
        })
      });
      setStatus($('dashStatus'), d.message || 'Policy saved.', 'ok');
      closeModal('modalPolicy');
    } catch (e) {
      setStatus($('dashStatus'), e.message, 'err');
    }
  }

  function updateMountActionButtons(d) {
    const btnW = $('btnInstallWinFsp');
    const btnP = $('btnStoreResticPass');
    if (btnW) {
      btnW.classList.toggle('hidden', !!d.winfspOk || !!d.running);
    }
    if (btnP) {
      btnP.classList.toggle('hidden', !!d.running);
      if (!d.resticCredOk) {
        btnP.classList.add('primary');
        btnP.classList.remove('soft');
      } else {
        btnP.classList.add('soft');
        btnP.classList.remove('primary');
      }
    }
  }

  async function refreshMountStatus() {
    const el = $('mountStatus');
    if (!el) return;
    try {
      const sid = state.activeSetId || 'set1';
      const d = await api('/api/mount/status?setId=' + encodeURIComponent(sid));
      state.winfspOk = !!d.winfspOk;
      let text = '';
      let kind = '';
      if (d.running) {
        text = 'Mounted: ' + (d.mountPoint || '') + (d.setId ? (' (' + d.setId + ')') : '');
        kind = 'ok';
      } else if (!d.winfspOk) {
        text = d.winfspMessage || 'Mount needs WinFsp (lets SyncMe show the backup as a folder).';
        kind = 'warn';
      } else if (!d.resticCredOk) {
        text = d.resticCredMessage || 'Repository password is not stored for this set.';
        kind = 'warn';
      } else {
        text = 'Not mounted';
        kind = '';
      }
      updateMountActionButtons(d);
      setStatus(el, text, kind);
    } catch (e) {
      setStatus(el, e.message, 'err');
    }
  }

  async function startMount() {
    setStatus($('mountStatus'), 'Starting restic mount…', 'busy');
    try {
      const d = await api('/api/mount/start', {
        method: 'POST',
        body: JSON.stringify({ setId: state.activeSetId || 'set1' })
      });
      setStatus($('mountStatus'), d.message || 'Mounted.', 'ok');
      await refreshMountStatus();
    } catch (e) {
      setStatus($('mountStatus'), e.message, 'err');
      await refreshMountStatus();
    }
  }

  async function stopMount() {
    setStatus($('mountStatus'), 'Unmounting…', 'busy');
    try {
      const d = await api('/api/mount/stop', { method: 'POST', body: '{}' });
      setStatus($('mountStatus'), d.message || 'Unmounted.', 'ok');
      await refreshMountStatus();
    } catch (e) {
      setStatus($('mountStatus'), e.message, 'err');
    }
  }

  async function installWinFspFromOps() {
    const btn = $('btnInstallWinFsp');
    if (btn) btn.disabled = true;
    setStatus($('mountStatus'), 'Downloading WinFsp installer… Approve the Windows security prompt if asked.', 'busy');
    try {
      const d = await api('/api/prereqs/install-winfsp', { method: 'POST', body: '{}' });
      state.winfspOk = !!d.winfspOk;
      setStatus($('mountStatus'), d.message || 'WinFsp installed.', d.winfspOk ? 'ok' : 'warn');
      await refreshMountStatus();
    } catch (e) {
      setStatus($('mountStatus'), e.message, 'err');
      if (btn) btn.disabled = false;
      await refreshMountStatus();
    }
  }

  function openStorePasswordModal() {
    const p1 = $('resticPassInput');
    const p2 = $('resticPassInput2');
    if (p1) p1.value = '';
    if (p2) p2.value = '';
    setStatus($('resticPassStatus'), '', '');
    openModal('modalResticPass');
  }

  async function saveResticPassword() {
    const p1 = ($('resticPassInput') && $('resticPassInput').value) || '';
    const p2 = ($('resticPassInput2') && $('resticPassInput2').value) || '';
    if (!p1) {
      setStatus($('resticPassStatus'), 'Enter the repository password.', 'err');
      return;
    }
    if (p1 !== p2) {
      setStatus($('resticPassStatus'), 'Passwords do not match.', 'err');
      return;
    }
    setStatus($('resticPassStatus'), 'Saving…', 'busy');
    try {
      const d = await api('/api/set/restic-password', {
        method: 'POST',
        body: JSON.stringify({ setId: state.activeSetId || 'set1', password: p1 })
      });
      setStatus($('resticPassStatus'), d.message || 'Password stored.', 'ok');
      if ($('resticPassInput')) $('resticPassInput').value = '';
      if ($('resticPassInput2')) $('resticPassInput2').value = '';
      await refreshMountStatus();
      setTimeout(() => closeModal('modalResticPass'), 800);
    } catch (e) {
      setStatus($('resticPassStatus'), e.message, 'err');
    }
  }

  function opsStatusEl() {
    return $('opsStatus') || $('dashStatus');
  }

  async function runBackup(mode) {
    if (mode === 'pruneOnly') {
      if (!confirm('Run forget --prune now for the active set?\n\nThis permanently removes snapshots outside the retention policy and cleans unreferenced data.')) {
        return;
      }
    }
    const st = opsStatusEl();
    setStatus(st, 'Starting backup job…', 'busy');
    setStatus($('dashStatus'), 'Starting backup job…', 'busy');
    try {
      const d = await api('/api/backup', {
        method: 'POST',
        body: JSON.stringify({ mode: mode || '', setId: state.activeSetId || 'set1' })
      });
      setStatus(st, d.message || 'Backup started.', 'ok');
      setStatus($('dashStatus'), d.message || 'Backup started.', 'ok');
      pollBackup();
    } catch (e) {
      setStatus(st, e.message, 'err');
      setStatus($('dashStatus'), e.message, 'err');
    }
  }

  async function pollBackup() {
    if (state.pollTimer) {
      clearTimeout(state.pollTimer);
      state.pollTimer = null;
    }
    try {
      const q = state.activeSetId ? ('?setId=' + encodeURIComponent(state.activeSetId)) : '';
      const d = await api('/api/backup/status' + q);
      updateProgressUI(d);
      if (d.running) {
        setStatus($('dashStatus'), 'Backup running… ' + (d.detail || d.message || ''), 'warn');
        setStatus($('opsStatus'), 'Backup running… ' + (d.detail || d.message || ''), 'warn');
        setTop('Backup running', 'warn');
        state.pollTimer = setTimeout(pollBackup, 2000);
      } else if (d.finished) {
        setStatus($('dashStatus'), d.message || ('Finished (exit ' + d.exitCode + ').'), d.exitCode === 0 ? 'ok' : 'warn');
        setStatus($('opsStatus'), d.message || ('Finished (exit ' + d.exitCode + ').'), d.exitCode === 0 ? 'ok' : 'warn');
        loadDash();
      }
    } catch (e) { /* ignore poll errors */ }
  }

  async function refreshSnaps() {
    setStatus($('restoreStatus'), 'Loading snapshots…', 'busy');
    try {
      const q = state.activeSetId ? ('?setId=' + encodeURIComponent(state.activeSetId)) : '';
      const d = await api('/api/snapshots' + q);
      state.snaps = d.snapshots || [];
      state.selectedSnap = -1;
      const ul = $('snapList');
      ul.innerHTML = '';
      if (!state.snaps.length) {
        ul.innerHTML = '<li>No snapshots yet.</li>';
        setStatus($('restoreStatus'), 'No snapshots found.', 'warn');
        return;
      }
      state.snaps.forEach((s, i) => {
        const li = document.createElement('li');
        li.textContent = s.Display || (s.ShortId + '  ' + s.Time);
        li.onclick = () => {
          state.selectedSnap = i;
          Array.from(ul.children).forEach((c) => c.classList.remove('selected'));
          li.classList.add('selected');
        };
        ul.appendChild(li);
      });
      setStatus($('restoreStatus'), 'Loaded ' + state.snaps.length + ' snapshot(s). Select one to restore, or use Restore latest.', 'ok');
    } catch (e) {
      setStatus($('restoreStatus'), e.message, 'err');
    }
  }

  async function doRestore(snapshot) {
    setStatus($('restoreStatus'), 'Restoring… this can take a while on large snapshots.', 'busy');
    try {
      const d = await api('/api/restore', {
        method: 'POST',
        body: JSON.stringify({
          snapshot: snapshot,
          target: $('restoreTarget').value,
          include: $('restoreInclude').value,
          setId: state.activeSetId || 'set1'
        })
      });
      setStatus($('restoreStatus'), d.message || 'Restore finished.', 'ok');
    } catch (e) {
      setStatus($('restoreStatus'), e.message, 'err');
    }
  }

  async function loadSetIntoForm(setId) {
    const d = await api('/api/set?setId=' + encodeURIComponent(setId || 'set1'));
    const f = state.form;
    f.setId = d.id || setId;
    f.displayName = d.displayName || f.displayName;
    f.networkMode = d.networkMode || 'both';
    f.destinationType = d.destinationType || 'local';
    f.sourceHost = d.sourceHost || '';
    f.sourcePaths = (d.sourcePaths && d.sourcePaths.length) ? d.sourcePaths : [''];
    f.resticRepo = d.resticRepo || '';
    f.archivePath = d.archivePath || '';
    f.resticPath = d.resticPath || 'restic';
    f.runTime = d.runTime || '01:00';
    f.scheduleStartDate = d.scheduleStartDate || f.scheduleStartDate;
    f.scheduleRecurrence = d.scheduleRecurrence || 'Daily';
    f.scheduleEndDate = d.scheduleEndDate || '';
    f.scheduleDaysOfWeek = (d.scheduleDaysOfWeek && d.scheduleDaysOfWeek.length) ? d.scheduleDaysOfWeek : WEEKDAYS.slice();
    f.enableEmail = !!d.enableEmail;
    f.smtpServer = d.smtpServer || f.smtpServer;
    f.smtpPort = String(d.smtpPort || f.smtpPort);
    f.smtpSsl = d.smtpSsl !== false;
    f.mailFrom = d.mailFrom || '';
    f.mailTo = d.mailTo || '';
    f.enableToast = d.enableToast === true;
    f.useShadowCopy = d.useShadowCopy !== false;
    f.enableWakeOnLan = !!d.enableWakeOnLan;
    f.wakeMac = d.wakeMac || '';
    f.storeShare = !!d.storeShare;
    f.keepLast = d.keepLast != null ? d.keepLast : 7;
    f.keepDaily = d.keepDaily != null ? d.keepDaily : 14;
    f.keepWeekly = d.keepWeekly != null ? d.keepWeekly : 8;
    f.keepMonthly = d.keepMonthly != null ? d.keepMonthly : 6;
    f.enableRepoCheck = d.enableRepoCheck !== false;
    f.weeklyDataCheckDay = d.weeklyDataCheckDay || 'Sunday';
    f.resticLimitUploadKByte = d.resticLimitUploadKByte != null ? d.resticLimitUploadKByte : 0;
    f.rcloneRemote = d.rcloneRemote || '';
    f.rcloneSubPath = d.rcloneSubPath || '';
    f.rcloneBwLimit = d.rcloneBwLimit || 'off';
    f.rcloneTransfers = d.rcloneTransfers != null ? d.rcloneTransfers : 4;
    f.rcloneCheckers = d.rcloneCheckers != null ? d.rcloneCheckers : 8;
    f.rcloneRetries = d.rcloneRetries != null ? d.rcloneRetries : 3;
    f.rcloneLowLevelRetries = d.rcloneLowLevelRetries != null ? d.rcloneLowLevelRetries : 10;
    f.rcloneMultiThreadStreams = d.rcloneMultiThreadStreams != null ? d.rcloneMultiThreadStreams : 4;
    f.resticPassword = '';
    f.resticPassword2 = '';
  }

  async function openEditSet(setId) {
    try {
      state.step = 0;
      state.isNewSet = false;
      await loadSetIntoForm(setId || state.activeSetId || 'set1');
      renderSteps();
      renderSetupBody();
      show('view-setup');
    } catch (e) {
      alert(e.message);
    }
  }

  async function deleteSet(id) {
    const setId = id || state.activeSetId || 'set1';
    if (!confirm('Delete backup set "' + setId + '" and its scheduled task?\n\nThe restic repository on disk will NOT be deleted.')) return;
    try {
      const d = await api('/api/set/delete', { method: 'POST', body: JSON.stringify({ setId: setId }) });
      setStatus(opsStatusEl(), d.message || 'Deleted.', 'ok');
      state.activeSetId = '';
      await loadDash();
    } catch (e) {
      setStatus(opsStatusEl(), e.message, 'err');
    }
  }

  async function cancelBackup() {
    const ok = confirm('Cancel the running backup now?\n\nThis stops the current run immediately and may leave a partial/incomplete run result.');
    if (!ok) return;
    setStatus(opsStatusEl(), 'Cancelling backup…', 'busy');
    try {
      const d = await api('/api/backup/cancel', { method: 'POST', body: '{}' });
      setStatus(opsStatusEl(), d.message || 'Cancelled.', 'warn');
      setStatus($('dashStatus'), d.message || 'Cancelled.', 'warn');
      updateProgressUI({ running: false, finished: true, message: d.message, percent: null });
      loadDash();
    } catch (e) {
      setStatus(opsStatusEl(), e.message, 'err');
    }
  }

  async function wakeSource() {
    setStatus(opsStatusEl(), 'Sending Wake-on-LAN…', 'busy');
    try {
      const d = await api('/api/wake', { method: 'POST', body: JSON.stringify({ setId: state.activeSetId || 'set1' }) });
      setStatus(opsStatusEl(), d.message || 'WoL sent.', 'ok');
    } catch (e) {
      setStatus(opsStatusEl(), e.message, 'err');
    }
  }

  async function updateResticPath() {
    const current = state.form && state.form.resticPath ? state.form.resticPath : 'restic';
    const input = prompt(
      'Set ResticPath for the active set.\nUse "restic" for PATH lookup, or a full path to restic.exe.',
      current
    );
    if (input == null) return;
    const resticPath = input.trim();
    if (!resticPath) {
      setStatus(opsStatusEl(), 'ResticPath was not changed.', 'warn');
      return;
    }
    setStatus(opsStatusEl(), 'Updating ResticPath…', 'busy');
    try {
      const d = await api('/api/set/restic-path', {
        method: 'POST',
        body: JSON.stringify({ setId: state.activeSetId || 'set1', resticPath: resticPath })
      });
      setStatus(opsStatusEl(), d.message || 'ResticPath updated.', 'ok');
      await loadDash();
    } catch (e) {
      setStatus(opsStatusEl(), e.message, 'err');
    }
  }

  async function openPath(kind) {
    try {
      await api('/api/open', { method: 'POST', body: JSON.stringify({ kind: kind, setId: state.activeSetId || 'set1' }) });
    } catch (e) {
      alert(e.message);
    }
  }

  $('btnBack').onclick = () => {
    collectForm();
    if (state.step > 0) {
      state.step--;
      renderSteps();
      renderSetupBody();
      setStatus($('setupStatus'), '', '');
    }
  };
  $('btnNext').onclick = async () => {
    if (state.step === 1) {
      try {
        const d = await api('/api/prereqs');
        state.resticOk = !!d.resticOk;
        state.rcloneOk = !!d.rcloneOk;
        state.winfspOk = !!d.winfspOk;
        if (d.resticOk && d.resticPath) {
          const el = document.getElementById('fRestic');
          if (el) el.value = d.resticPath;
          state.form.resticPath = d.resticPath;
        }
        updateInstallResticBtn();
        updateInstallRcloneBtn();
        updateInstallWinFspBtn();
      } catch (e) {
        state.resticOk = false;
      }
    }
    const err = validateStep();
    if (err) { setStatus($('setupStatus'), err, 'err'); return; }
    setStatus($('setupStatus'), '', '');
    if (state.step === steps.length - 1) {
      await applySetup();
      return;
    }
    state.step++;
    renderSteps();
    renderSetupBody();
  };

  if ($('btnWizardDryRun')) {
    $('btnWizardDryRun').onclick = () => wizardDryRun();
  }

  document.querySelectorAll('[data-backup]').forEach((btn) => {
    btn.addEventListener('click', () => runBackup(btn.getAttribute('data-backup')));
  });

  document.querySelectorAll('[data-close-modal]').forEach((el) => {
    el.addEventListener('click', () => closeModal(el.getAttribute('data-close-modal')));
  });
  document.addEventListener('keydown', (e) => {
    if (e.key === 'Escape') {
      closeModal('modalCloud');
      closeModal('modalPolicy');
      closeModal('modalResticPass');
    }
  });

  if ($('btnOpenCloudModal')) {
    $('btnOpenCloudModal').onclick = async () => {
      await fillDashPolicyAndCloud();
      openModal('modalCloud');
    };
  }
  if ($('btnOpenPolicyModal')) {
    $('btnOpenPolicyModal').onclick = async () => {
      await fillDashPolicyAndCloud();
      openModal('modalPolicy');
    };
  }
  if ($('btnGotoOps')) {
    $('btnGotoOps').onclick = () => { show('view-ops'); refreshSnaps(); loadDash(); };
  }

  if ($('btnOpsMore')) {
    $('btnOpsMore').onclick = () => {
      const p = $('opsMorePanel');
      if (p) p.classList.toggle('hidden');
    };
  }

  $('btnOpenReports').onclick = () => openPath('reports');
  if ($('btnOpenReportsDash')) $('btnOpenReportsDash').onclick = () => openPath('reports');
  if ($('btnOpenLastLog')) $('btnOpenLastLog').onclick = () => openPath('logs');
  $('btnOpenLogs').onclick = () => openPath('logs');

  if ($('btnAddSet')) {
    $('btnAddSet').onclick = () => {
      state.step = 0;
      state.isNewSet = true;
      state.form.setId = '';
      state.form.displayName = 'Backup set ' + ((state.sets.length || 0) + 1);
      state.form.sourcePaths = [''];
      state.form.resticRepo = '';
      state.form.archivePath = '';
      state.form.sourceHost = '';
      state.form.resticPassword = '';
      state.form.resticPassword2 = '';
      renderSteps();
      renderSetupBody();
      show('view-setup');
    };
  }
  if ($('btnCancelBackup')) $('btnCancelBackup').onclick = () => cancelBackup();
  if ($('btnWakeSource')) $('btnWakeSource').onclick = () => wakeSource();
  if ($('btnSetResticPath')) $('btnSetResticPath').onclick = () => updateResticPath();
  if ($('btnRcloneRefresh')) $('btnRcloneRefresh').onclick = () => refreshRcloneRemotes('rcloneRemote', 'rcloneStatus');
  if ($('btnRcloneAddOneDrive')) $('btnRcloneAddOneDrive').onclick = () => startRcloneOAuth('onedrive', 'rcloneStatus', 'rcloneRemote');
  if ($('btnRcloneAddDrive')) $('btnRcloneAddDrive').onclick = () => startRcloneOAuth('drive', 'rcloneStatus', 'rcloneRemote');
  if ($('btnRcloneCancelOAuth')) $('btnRcloneCancelOAuth').onclick = () => cancelRcloneOAuth('rcloneStatus');
  if ($('btnRcloneSave')) $('btnRcloneSave').onclick = () => saveRcloneCloud();
  if ($('btnRcloneTest')) $('btnRcloneTest').onclick = () => testRcloneCloud();
  if ($('btnSavePolicy')) $('btnSavePolicy').onclick = () => savePolicy();
  if ($('btnMountStart')) $('btnMountStart').onclick = () => startMount();
  if ($('btnMountStop')) $('btnMountStop').onclick = () => stopMount();
  if ($('btnInstallWinFsp')) $('btnInstallWinFsp').onclick = () => installWinFspFromOps();
  if ($('btnStoreResticPass')) $('btnStoreResticPass').onclick = () => openStorePasswordModal();
  if ($('btnSaveResticPass')) $('btnSaveResticPass').onclick = () => saveResticPassword();
  if ($('btnOpenOfficeAgent')) $('btnOpenOfficeAgent').onclick = () => openPath('officeagent');

  $('navSetup').onclick = (e) => {
    e.preventDefault();
    state.step = 0;
    state.isNewSet = false;
    renderSteps();
    renderSetupBody();
    show('view-setup');
  };
  $('navDash').onclick = (e) => {
    e.preventDefault();
    show('view-dash');
    loadDash();
  };
  $('navOps').onclick = (e) => {
    e.preventDefault();
    show('view-ops');
    loadDash();
    refreshSnaps();
  };

  $('btnRefreshSnaps').onclick = refreshSnaps;
  $('btnRestoreLatest').onclick = () => doRestore('latest');
  $('btnRestoreSel').onclick = () => {
    if (state.selectedSnap < 0) { setStatus($('restoreStatus'), 'Select a snapshot first.', 'warn'); return; }
    doRestore(state.snaps[state.selectedSnap].Id);
  };
  $('btnOpenChecklist').onclick = () => openPath('checklist');
  $('btnSuggestTarget').onclick = async () => {
    try {
      const q = state.activeSetId ? ('?setId=' + encodeURIComponent(state.activeSetId)) : '';
      const d = await api('/api/status' + q);
      if (d.defaultRestoreTarget) $('restoreTarget').value = d.defaultRestoreTarget;
    } catch (e) { alert(e.message); }
  };

  async function boot() {
    try {
      const d = await api('/api/status');
      if (forceSetup || (!d.configured && !forceConsole)) {
        renderSteps();
        renderSetupBody();
        show('view-setup');
        setTop('Needs setup', 'warn');
      } else {
        show('view-dash');
        await loadDash();
      }
    } catch (e) {
      setTop('Host error', 'danger');
      alert('Cannot reach SyncMe host: ' + e.message);
    }
  }

  function runSplashThenBoot() {
    const splash = $('splash');
    const holdMs = 2200;
    const fadeMs = 600;
    window.setTimeout(() => {
      if (splash) {
        splash.classList.add('fade-out');
        splash.setAttribute('aria-hidden', 'true');
      }
      document.body.classList.add('app-ready');
      window.setTimeout(() => {
        if (splash && splash.parentNode) splash.parentNode.removeChild(splash);
      }, fadeMs);
      boot();
    }, holdMs);
  }

  runSplashThenBoot();
})();

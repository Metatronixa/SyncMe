(function () {
  'use strict';

  function esc(s) {
    return String(s == null ? '' : s)
      .replace(/&/g, '&amp;')
      .replace(/</g, '&lt;')
      .replace(/>/g, '&gt;')
      .replace(/"/g, '&quot;');
  }

  function ageLabel(iso) {
    if (!iso) return '—';
    const t = Date.parse(iso);
    if (!t) return esc(iso);
    const mins = Math.round((Date.now() - t) / 60000);
    if (mins < 1) return 'just now';
    if (mins < 60) return mins + 'm ago';
    const hrs = Math.round(mins / 60);
    if (hrs < 48) return hrs + 'h ago';
    return Math.round(hrs / 24) + 'd ago';
  }

  function classify(site) {
    if (site.phase === 'running' || (site.percent > 0 && site.percent < 100 && site.phase !== 'done' && site.phase !== 'error')) {
      return { cls: 'warn', text: 'Running', bucket: 'running' };
    }
    if (site.success === false || site.phase === 'error') {
      return { cls: 'danger', text: 'Failed', bucket: 'failed' };
    }
    const t = Date.parse(site.endedUtc || site.receivedUtc || '');
    if (t && (Date.now() - t) > 2 * 24 * 3600 * 1000) {
      return { cls: 'warn', text: 'Stale', bucket: 'attention' };
    }
    if ((site.summary || '').indexOf('Test heartbeat') === 0 || (site.setId || '') === 'test') {
      return { cls: 'ok', text: 'OK', bucket: 'healthy' };
    }
    return { cls: 'ok', text: 'OK', bucket: 'healthy' };
  }

  function setText(id, value) {
    const el = document.getElementById(id);
    if (el) el.textContent = String(value);
  }

  async function loadSites() {
    const list = document.getElementById('siteList');
    const hint = document.getElementById('emptyHint');
    try {
      const res = await fetch('/api/sites');
      const d = await res.json();
      const sites = d.sites || [];
      setText('siteCount', sites.length + (sites.length === 1 ? ' site' : ' sites'));

      let healthy = 0, attention = 0, failed = 0, running = 0;
      sites.forEach((s) => {
        const c = classify(s);
        if (c.bucket === 'healthy') healthy++;
        else if (c.bucket === 'attention') attention++;
        else if (c.bucket === 'failed') failed++;
        else if (c.bucket === 'running') running++;
      });
      setText('statHealthy', healthy);
      setText('statAttention', attention);
      setText('statFailed', failed);
      setText('statRunning', running);

      if (!sites.length) {
        list.innerHTML = '';
        if (hint) hint.classList.remove('hidden');
        return;
      }
      if (hint) hint.classList.add('hidden');

      list.innerHTML = sites.map((s) => {
        const b = classify(s);
        const title = esc(s.siteId || s.hostname || 'site');
        const setLine = esc((s.setName || s.setId || '') + (s.version ? (' · SyncMe ' + s.version) : ''));
        const host = s.hostname ? (' · <code>' + esc(s.hostname) + '</code>') : '';
        const summary = esc(s.summary || '');
        const when = ageLabel(s.endedUtc || s.receivedUtc);
        let progress = '';
        if (b.bucket === 'running' && s.percent != null) {
          const pct = Math.max(0, Math.min(100, Number(s.percent) || 0));
          progress = '<div class="progress" aria-hidden="true"><span style="width:' + pct + '%"></span></div>';
        }
        return (
          '<article class="site-row">' +
            '<div>' +
              '<h3>' + title + '</h3>' +
              '<div class="site-meta">' + setLine + host + '</div>' +
              '<div class="site-meta">' + summary + '</div>' +
              progress +
              '<div class="site-foot"><span>Last report: ' + when + '</span></div>' +
            '</div>' +
            '<span class="badge ' + b.cls + '">' + b.text + '</span>' +
          '</article>'
        );
      }).join('');
    } catch (e) {
      list.innerHTML = '<p class="sub">Failed to load sites: ' + esc(e.message) + '</p>';
    }
  }

  document.getElementById('btnRefresh').onclick = () => loadSites();
  loadSites();
  setInterval(loadSites, 10000);
})();

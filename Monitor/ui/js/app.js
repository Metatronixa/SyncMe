(function () {
  'use strict';

  function ageLabel(iso) {
    if (!iso) return '—';
    const t = Date.parse(iso);
    if (!t) return String(iso);
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

  function el(tag, className, text) {
    const node = document.createElement(tag);
    if (className) node.className = className;
    if (text != null && text !== '') node.textContent = String(text);
    return node;
  }

  function renderSite(s) {
    const b = classify(s);
    const article = el('article', 'site-row');
    const left = el('div');

    left.appendChild(el('h3', null, s.siteId || s.hostname || 'site'));

    const meta1 = el('div', 'site-meta');
    meta1.appendChild(document.createTextNode(
      (s.setName || s.setId || '') + (s.version ? (' · SyncMe ' + s.version) : '')
    ));
    if (s.hostname) {
      meta1.appendChild(document.createTextNode(' · '));
      meta1.appendChild(el('code', null, s.hostname));
    }
    left.appendChild(meta1);

    if (s.summary) left.appendChild(el('div', 'site-meta', s.summary));

    if (b.bucket === 'running' && s.percent != null) {
      const pct = Math.max(0, Math.min(100, Number(s.percent) || 0));
      const bar = el('div', 'progress');
      bar.setAttribute('aria-hidden', 'true');
      const fill = el('span');
      fill.style.width = pct + '%';
      bar.appendChild(fill);
      left.appendChild(bar);
    }

    const foot = el('div', 'site-foot');
    foot.appendChild(el('span', null, 'Last report: ' + ageLabel(s.endedUtc || s.receivedUtc)));
    left.appendChild(foot);

    article.appendChild(left);
    article.appendChild(el('span', 'badge ' + b.cls, b.text));
    return article;
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

      while (list.firstChild) list.removeChild(list.firstChild);

      if (!sites.length) {
        if (hint) hint.classList.remove('hidden');
        return;
      }
      if (hint) hint.classList.add('hidden');

      sites.forEach((s) => list.appendChild(renderSite(s)));
    } catch (e) {
      while (list.firstChild) list.removeChild(list.firstChild);
      list.appendChild(el('p', 'sub', 'Failed to load sites: ' + (e && e.message ? e.message : String(e))));
    }
  }

  document.getElementById('btnRefresh').onclick = () => loadSites();
  loadSites();
  setInterval(loadSites, 10000);
})();

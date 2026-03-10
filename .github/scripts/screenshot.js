'use strict';

const puppeteer = require('puppeteer');
const http      = require('http');
const fs        = require('fs');
const path      = require('path');
const { URL }   = require('url');

const ROOT  = path.join(__dirname, '../..');
const WWW   = path.join(ROOT, 'PortableApps/26_raytrap/raytrap/www');
const ASSETS = path.join(ROOT, 'assets');
const PORT  = 3737;

// ── Mock CGI responses ─────────────────────────────────────────────────────────

const MOCKS = {
  'status.cgi': {
    all: { ok:true, data:{
      ipt_running:true, ipt_pid:212, proxy_running:false, proxy_pid:null,
      wpa_running:false, wpa_pid:null, wlan1_up:false, wlan1_state:'DISCONNECTED',
      wlan1_ip:'', cap_running:false, rule_count:2, uptime:'3h 22m',
      cache_free:'18.4 MB', data_free:'174.6 MB', kernel:'3.18.48-perf-g7c5d8a2'
    }}
  },
  'diag.cgi': {
    status: { ok:true, data:{
      rayhunter:  { running:true, pid:456, port:8080, fork_stream:true, debug_mode:false },
      interfaces: { wifi:'192.168.1.1', rndis:'192.168.42.1', adb:'127.0.0.1' },
      stream_port:37026, qcmap:{ running:true, pid:789 },
      mask:{ lte_rrc:true, lte_nas:true, lte_l1:false, lte_mac:false, lte_rlc:false,
             lte_pdcp:false, nr_rrc:true, wcdma:true, gsm:true, umts_nas:true,
             ip_data:true, f3_debug:false, gps:false, qmi_events:false }
    }},
    diag_owner_get: { ok:true, data:{ diag_owner:'rayhunter' }},
    get_mask: { ok:true, data:{
      lte_rrc:true, lte_nas:true, lte_l1:false, lte_mac:false, lte_rlc:false,
      lte_pdcp:false, nr_rrc:true, wcdma:true, gsm:true, umts_nas:true,
      ip_data:true, f3_debug:false, gps:false, qmi_events:false
    }}
  },
  'firewall.cgi': {
    list: { ok:true, data:[
      { num:1, table:'nat', chain:'PREROUTING', target:'REDIRECT', src:'0.0.0.0/0',
        dst:'0.0.0.0/0', opts:'tcp dpt:80 redir ports 8118', friendly:'Redirect port 80 \u2192 8118' },
      { num:2, table:'filter', chain:'INPUT', target:'DROP', src:'192.168.1.105',
        dst:'0.0.0.0/0', opts:'', friendly:'Block 192.168.1.105' }
    ]}
  },
  'proxy.cgi': {
    status: { ok:true, data:{ running:false, pid:null, transparent:false }},
    log:    { ok:true, data:'' }
  },
  'wifi.cgi': {
    status: { ok:true, data:{
      wpa_running:false, wpa_pid:null, wpa_state:'DISCONNECTED', ssid:'', ip_address:'',
      networks:[{ id:0, ssid:'HomeNetwork', current:false },{ id:1, ssid:'LabAP', current:false }],
      raw:''
    }}
  },
  'routing.cgi': {
    list: { ok:true, data:{
      rules:[
        { priority:'0',     from:'all', table:'local',   desc:'local'   },
        { priority:'32766', from:'all', table:'main',    desc:'main'    },
        { priority:'32767', from:'all', table:'default', desc:'default' }
      ],
      raw:'0:\tfrom all lookup local\n32766:\tfrom all lookup main\n32767:\tfrom all lookup default'
    }}
  },
  'capture.cgi': {
    status: { ok:true, data:{
      file:{ running:false, pid:null, iface:null, file:null, elapsed:null },
      stream:{ running:false, port:37027, wifi_ip:null, rndis_ip:null },
      ifaces:['rmnet_data0','wlan0','wlan1','lo'], files:[]
    }}
  }
};

// ── HTTP server ────────────────────────────────────────────────────────────────

const MIME = { '.html':'text/html', '.js':'application/javascript', '.css':'text/css', '.png':'image/png' };

function serveMock(res, cgiName, action) {
  const cgi  = MOCKS[cgiName] || {};
  const data = cgi[action] || cgi[Object.keys(cgi)[0]] || { ok:false, error:'no mock' };
  res.writeHead(200, { 'Content-Type':'application/json', 'Access-Control-Allow-Origin':'*' });
  res.end(JSON.stringify(data));
}

function serveStatic(res, urlPath) {
  const filePath = path.resolve(path.join(WWW, urlPath === '/' ? '/index.html' : urlPath));
  if (!filePath.startsWith(path.resolve(WWW))) { res.writeHead(403); res.end(); return; }
  try {
    const content = fs.readFileSync(filePath);
    res.writeHead(200, { 'Content-Type': MIME[path.extname(filePath)] || 'text/plain' });
    res.end(content);
  } catch { res.writeHead(404); res.end('Not found'); }
}

const server = http.createServer((req, res) => {
  const parsed = new URL(req.url, `http://localhost:${PORT}`);
  if (parsed.pathname.startsWith('/cgi-bin/')) {
    const cgiName = path.basename(parsed.pathname);
    if (req.method === 'POST') {
      let body = '';
      req.on('data', c => body += c);
      req.on('end', () => {
        const p = Object.fromEntries(new URLSearchParams(body));
        serveMock(res, cgiName, p.action || parsed.searchParams.get('action') || '');
      });
    } else {
      serveMock(res, cgiName, parsed.searchParams.get('action') || '');
    }
    return;
  }
  serveStatic(res, parsed.pathname);
});

// ── Screenshots only — GIF is built by the workflow shell step ─────────────────

const TABS = ['dashboard', 'firewall', 'proxy', 'wifi', 'routing', 'capture'];

async function run() {
  await new Promise(r => server.listen(PORT, r));
  console.log('Mock server ready on :' + PORT);

  const browser = await puppeteer.launch({
    args: ['--no-sandbox', '--disable-setuid-sandbox', '--disable-dev-shm-usage', '--disable-gpu'],
    defaultViewport: { width:1440, height:900 }
  });

  const page = await browser.newPage();

  await page.goto('http://localhost:' + PORT + '/', { waitUntil:'networkidle0', timeout:30000 });

  for (const tab of TABS) {
    if (tab !== 'dashboard') {
      await page.click('nav button[data-tab="' + tab + '"]');
      await page.waitForNetworkIdle({ idleTime:600, timeout:15000 }).catch(() => {});
    }
    await new Promise(r => setTimeout(r, 600));
    const out = path.join(ASSETS, 'raytrap_' + tab + '.png');
    await page.screenshot({ path: out });
    console.log('screenshot: ' + out);
  }

  await browser.close();
  server.close();
  console.log('done');
}

run().catch(e => { console.error('FATAL:', e); process.exit(1); });

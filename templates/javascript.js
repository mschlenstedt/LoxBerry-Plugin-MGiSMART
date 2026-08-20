<script>

// Shared JavaScript for all tabs. Appended to every template, so it may use
// TMPL_VAR tags for localized strings. Data comes from ajax.cgi (relative URL).

// Styles that are not part of the LoxBerry Design System: the gateway service
// status block shown in the header of every tab except Log files.
(function() {
	var css =
		".gwsvc{display:flex;flex-wrap:wrap;justify-content:center;align-items:center;gap:10px;text-shadow:none;padding:6px 0;}" +
		".gwsvc-info{display:flex;align-items:center;gap:10px;flex-wrap:wrap;justify-content:center;}" +
		".gwsvc-btns{display:flex;flex-wrap:wrap;gap:4px;justify-content:center;align-items:center;}" +
		".gwsvc-label{color:var(--lb-text);}" +
		".gwsvc-box{padding:7px 12px;box-sizing:border-box;border-radius:5px;background:#dfdfdf;border:1px solid #7E7E7E;min-width:130px;max-width:100%;text-align:center;color:#333;}" +
		".gwsvc-small{font-size:80%;}" +
		".gwsvc-btn{display:inline-flex;align-items:center;gap:8px;background:#f6f6f6;border:1px solid #ddd;border-radius:5px;padding:6px 12px;color:#333;font-size:12.5px;font-weight:bold;line-height:1;text-decoration:none;cursor:pointer;}" +
		".gwsvc-btn:hover{background:#ededed;}" +
		".gwsvc-ico{display:inline-flex;align-items:center;justify-content:center;width:22px;height:22px;border-radius:50%;background:rgba(0,0,0,.3);color:#fff;font-size:12px;}" +
		".lb-form-label{white-space:nowrap;}" +
		// Warning box. Deliberately loud: it is about commanding a car and
		// exposing its position, so it must not read as a decorative hint.
		".mgi-warning{background:#fdecea;border:1px solid #d0021b;border-left:6px solid #d0021b;" +
			"border-radius:5px;padding:12px 16px;margin:0 0 20px;color:#5c1210;text-shadow:none;" +
			"font-size:0.9rem;line-height:1.55;}" +
		".mgi-warning p{margin:0 0 8px;}" +
		".mgi-warning p:last-child{margin-bottom:0;}" +
		".mgi-warning-title{font-weight:700;color:#d0021b;text-transform:uppercase;letter-spacing:.02em;}" +
		".mgi-pin{max-width:420px;margin:0 auto;padding:16px;border:1px solid var(--lb-border,#ccc);" +
			"border-radius:5px;text-align:center;}" +
		".mgi-pin-row{display:flex;gap:8px;align-items:center;margin:10px 0;}" +
		".mgi-pin-row .lb-input{flex:1;min-width:0;}";
	var style = document.createElement("style");
	style.textContent = css;
	document.head.appendChild(style);
})();

var gwInterval = null;

$(function() {
	// Service status block: present on every tab except Log files.
	if (document.getElementById("gw-service")) {
		gwServiceRender();
		gwServiceStatus();
		gwInterval = window.setInterval(gwServiceStatus, 5000);
	}

	// Gateway tab: cloud connection box, refreshed a little slower than the
	// process badge because every refresh talks to the MQTT broker.
	if (document.getElementById("cloud-online")) {
		cloudStatus();
		window.setInterval(cloudStatus, 15000);
	}

	// Settings tab: locked behind the SecurePIN, so nothing is loaded until it
	// has been accepted.
	if (document.getElementById("securepin_block")) {
		$("#check_securepin").click(mgiCheckPin);
		// The same session key the core's own pages use, so entering the PIN
		// once unlocks all of them for this browser session.
		$("#securepin").val(sessionStorage.getItem("securePIN") || "");
		if ($("#securepin").val()) { mgiCheckPin(); }
		else { $("#securepin_block").fadeIn(); }
	}

	// Update tab.
	if (document.getElementById("upg-btn")) {
		upgVersions(false);
	}
});

// ================================================================== HELPERS

function gwEsc(value) {
	return $("<div>").text(value == null ? "" : value).html();
}

// Coloured status line shown under a button: green = ok, red = error,
// blue = neutral/in progress.
function gwStatusLine(sel, text, kind) {
	var color = kind === "ok" ? "#4a9e2f" : (kind === "error" ? "#c0392b" : "#2274c6");
	$(sel).text(text).css({ display: "block", "text-align": "center", "margin-top": "0.5em", color: color });
}

// =========================================================== SERVICE BLOCK

var gwSvc = {
	LABEL:     "<TMPL_VAR COMMON.SERVICE_LABEL>",
	START:     "<TMPL_VAR COMMON.SERVICE_START>",
	RESTART:   "<TMPL_VAR COMMON.SERVICE_RESTART>",
	STOP:      "<TMPL_VAR COMMON.SERVICE_STOP>",
	STOPPED:   "<TMPL_VAR COMMON.SERVICE_STOPPED>",
	UNKNOWN:   "<TMPL_VAR COMMON.SERVICE_UNKNOWN>",
	WORKING:   "<TMPL_VAR COMMON.SERVICE_WORKING>",
	FAILED:    "<TMPL_VAR COMMON.SERVICE_FAILED>",
	NOTINST:   "<TMPL_VAR COMMON.SERVICE_NOTINSTALLED>"
};

function gwServiceRender() {
	document.getElementById("gw-service").innerHTML =
		'<div class="gwsvc">' +
			'<div class="gwsvc-info">' +
				'<div class="gwsvc-label">' + gwEsc(gwSvc.LABEL) + '</div>' +
				'<div id="gw-svc-icon"></div>' +
				'<div class="gwsvc-box" id="gw-svc-box">' + gwEsc(gwSvc.UNKNOWN) + '</div>' +
			'</div>' +
			'<div class="gwsvc-btns">' +
				'<a href="#" class="gwsvc-btn" onclick="gwServiceStart(); return false;"><span class="gwsvc-ico"><i class="pi pi-play"></i></span>' + gwEsc(gwSvc.START) + '</a>' +
				'<a href="#" class="gwsvc-btn" onclick="gwServiceRestart(); return false;"><span class="gwsvc-ico"><i class="pi pi-refresh"></i></span>' + gwEsc(gwSvc.RESTART) + '</a>' +
				'<a href="#" class="gwsvc-btn" onclick="gwServiceStop(); return false;"><span class="gwsvc-ico"><i class="pi pi-times"></i></span>' + gwEsc(gwSvc.STOP) + '</a>' +
			'</div>' +
		'</div><hr><br>';
	gwServiceIcon("unknown");
}

// Non-clickable status badge: green = running, orange-red = stopped or failed,
// grey = unknown or in transition.
function gwServiceIcon(kind) {
	var m = kind === "ok"    ? { i: "pi-check", bg: "#6dac20", fg: "#fff" }
	      : kind === "error" ? { i: "pi-times", bg: "#d0021b", fg: "#fff" }
	      : kind === "warn"  ? { i: "pi-exclamation-triangle", bg: "#f5a623", fg: "#fff" }
	      :                    { i: "pi-question", bg: "#9e9e9e", fg: "#fff" };
	$("#gw-svc-icon").html('<button type="button" tabindex="-1" class="lb-btn lb-btn-icon"' +
		' style="pointer-events:none; display:inline-flex; align-items:center; justify-content:center;' +
		' width:30px; height:30px; padding:0; margin:0; font-size:16px; line-height:1; box-sizing:border-box;' +
		' background:' + m.bg + '; border-color:' + m.bg + '; color:' + m.fg + '">' +
		'<i class="pi ' + m.i + '"></i></button>');
}

function gwServiceBox(style, html) {
	$("#gw-svc-box").attr("style", style).html(html);
}

function gwServiceFailed() {
	gwServiceBox("background:#dfdfdf; color:#f5a623", gwEsc(gwSvc.FAILED));
	gwServiceIcon("warn");
}

function gwServiceShow(data) {
	if (data && data.ok && data.running && data.pid) {
		gwServiceBox("background:#6dac20; color:black", '<span class="gwsvc-small">PID: ' + gwEsc(data.pid) + '</span>');
		gwServiceIcon("ok");
	} else if (data && data.ok && !data.installed) {
		// Nothing installed yet is a different situation from a crashed gateway,
		// and the user needs to be sent to the Update tab rather than the log.
		gwServiceBox("background:#dfdfdf; color:#333", gwEsc(gwSvc.NOTINST));
		gwServiceIcon("warn");
	} else if (data && data.ok) {
		gwServiceBox("background:#d0021b; color:white", gwEsc(gwSvc.STOPPED));
		gwServiceIcon("error");
	} else {
		gwServiceFailed();
	}
}

function gwServiceStatus() {
	$.ajax({ url: "ajax.cgi", type: "GET", dataType: "json", data: { action: "gw-status" } })
		.done(gwServiceShow)
		.fail(gwServiceFailed);
}

function gwServiceWorking() {
	gwServiceBox("background:#9e9e9e; color:white", gwEsc(gwSvc.WORKING));
	gwServiceIcon("unknown");
}

// Runs a mutating action. Start and restart can take a moment: the watchdog
// waits a few seconds to see whether the gateway stays alive, and the answer
// only arrives afterwards. While that runs the badge stays grey.
function gwServiceRun(action, pollForStart) {
	if (gwBusy) { return; }
	gwSetBusy(true);
	clearInterval(gwInterval);
	gwServiceWorking();
	$.ajax({ url: "ajax.cgi", type: "POST", dataType: "json", data: { action: action } })
		.done(function(data) {
			if (pollForStart && data && data.ok && !data.running) {
				// The process may still be coming up. Keep looking for a PID
				// before reporting a failure.
				gwPollRunning(0);
				return;
			}
			gwServiceShow(data);
			gwFinishAction();
		})
		.fail(function() { gwServiceFailed(); gwFinishAction(); });
}

// Polls for a running gateway for up to 15 seconds after a start or restart.
function gwPollRunning(attempt) {
	if (attempt > 5) {
		gwServiceStatus();
		gwFinishAction();
		return;
	}
	window.setTimeout(function() {
		$.ajax({ url: "ajax.cgi", type: "GET", dataType: "json", data: { action: "gw-status" } })
			.done(function(data) {
				if (data && data.ok && data.running) {
					gwServiceShow(data);
					gwFinishAction();
				} else {
					gwPollRunning(attempt + 1);
				}
			})
			.fail(function() { gwPollRunning(attempt + 1); });
	}, 2500);
}

function gwFinishAction() {
	gwSetBusy(false);
	gwInterval = window.setInterval(gwServiceStatus, 5000);
	// A start or stop changes what the cloud box can report, so refresh it too.
	if (document.getElementById("cloud-online")) { cloudStatus(); }
}

// While an action runs, lock out the buttons that would race with it.
var gwBusy = false;
function gwSetBusy(on) {
	gwBusy = !!on;
	$(".gwsvc-btn").css({ "pointer-events": on ? "none" : "", opacity: on ? "0.5" : "" });
	$(".gw-busy-disable").prop("disabled", !!on);
}

function gwServiceStart()   { gwServiceRun("gw-start", true); }
function gwServiceRestart() { gwServiceRun("gw-restart", true); }
function gwServiceStop()    { gwServiceRun("gw-stop", false); }

// ============================================================== GATEWAY TAB

var cloudText = {
	ONLINE:     "<TMPL_VAR MGISMART.CLOUD_STATE_ONLINE>",
	OFFLINE:    "<TMPL_VAR MGISMART.CLOUD_STATE_OFFLINE>",
	NOANSWER:   "<TMPL_VAR MGISMART.CLOUD_STATE_NOANSWER>",
	LOGINFAIL:  "<TMPL_VAR MGISMART.CLOUD_STATE_LOGINFAILED>",
	NOTCONFIG:  "<TMPL_VAR MGISMART.CLOUD_STATE_NOTCONFIGURED>",
	NEVER:      "<TMPL_VAR MGISMART.CLOUD_NEVER>"
};

// Turns the gateway's UTC ISO 8601 timestamps into local time. Anything that
// does not parse is shown unchanged rather than as "Invalid Date".
function cloudTime(value) {
	if (!value) { return cloudText.NEVER; }
	var d = new Date(value);
	if (isNaN(d.getTime())) { return value; }
	return d.toLocaleString();
}

function cloudSet(sel, text, color) {
	$(sel).text(text).css("color", color || "");
}

function cloudStatus() {
	$.ajax({ url: "ajax.cgi", type: "GET", dataType: "json", data: { action: "cloud-status" } })
		.done(function(data) {
			if (!data || !data.ok) { cloudSet("#cloud-online", cloudText.NOANSWER, "#f5a623"); return; }

			if (!data.configured) {
				cloudSet("#cloud-online", cloudText.NOTCONFIG, "#f5a623");
				cloudSet("#cloud-lastlogin", "-");
				cloudSet("#cloud-lasterror", "-");
				cloudSet("#cloud-gwversion", "-");
				$("#cloud-topic").text("-");
				return;
			}

			$("#cloud-topic").text(data.topic || "-");

			if (data.login_failed) {
				cloudSet("#cloud-online", cloudText.LOGINFAIL, "#d0021b");
			} else if (!data.answered) {
				cloudSet("#cloud-online", cloudText.NOANSWER, "#f5a623");
			} else if (data.online) {
				cloudSet("#cloud-online", cloudText.ONLINE, "#4a9e2f");
			} else {
				cloudSet("#cloud-online", cloudText.OFFLINE, "#d0021b");
			}

			cloudSet("#cloud-lastlogin", cloudTime(data.last_login));
			cloudSet("#cloud-lasterror", cloudTime(data.last_login_error),
				data.last_login_error ? "#c0392b" : "");
			cloudSet("#cloud-gwversion", data.gateway_version || "-");
		})
		.fail(function() { cloudSet("#cloud-online", cloudText.NOANSWER, "#f5a623"); });
}

// ================================================================ SECUREPIN

var pinMsg = {
	WAIT:    "<TMPL_VAR MGISMART.PIN_CHECKING>",
	WRONG:   "<TMPL_VAR MGISMART.PIN_WRONG>",
	LOCKED:  "<TMPL_VAR MGISMART.PIN_LOCKED>",
	FAILED:  "<TMPL_VAR MGISMART.PIN_FAILED>"
};

// The accepted PIN for this page. Every request that touches the configuration
// carries it, because ajax.cgi verifies it again server-side.
var mgiPin = null;

function mgiPinKeyPress(event) {
	event = event || window.event;
	if (event.keyCode === 13) { $("#check_securepin").click(); return false; }
	return true;
}

function mgiCheckPin() {
	var pin = $("#securepin").val();
	if (!pin) { return; }
	$("#check_securepin").prop("disabled", true);
	$("#check_hint").css("color", "#2274c6").text(pinMsg.WAIT);

	$.ajax({ url: "ajax.cgi", type: "POST", dataType: "json", data: { action: "checksecpin", secpin: pin } })
		.done(function(data) {
			if (!data || data.error) {
				// 3 means the core locked the PIN after repeated failures; saying
				// so avoids the user hammering a PIN that cannot succeed yet.
				var msg = (data && data.error === 3) ? pinMsg.LOCKED : pinMsg.WRONG;
				$("#check_hint").css("color", "#c0392b").text(msg);
				sessionStorage.removeItem("securePIN");
				$("#securepin_block").fadeIn();
				return;
			}
			mgiPin = pin;
			sessionStorage.setItem("securePIN", pin);
			$("#check_hint").html("&nbsp;");
			$("#securepin_block").fadeOut(function() { $("#main_content").fadeIn(); });
			setLoad();
		})
		.fail(function() {
			$("#check_hint").css("color", "#c0392b").text(pinMsg.FAILED);
			$("#securepin_block").fadeIn();
		})
		.always(function() { $("#check_securepin").prop("disabled", false); });
}

// ============================================================= SETTINGS TAB

var setMsg = {
	SAVING:        "<TMPL_VAR COMMON.HINT_SAVING>",
	SAVING_FAILED: "<TMPL_VAR COMMON.HINT_SAVING_FAILED>",
	SAVED_RESTART: "<TMPL_VAR COMMON.HINT_SAVED_RESTART>",
	SHOW:          "<TMPL_VAR MGISMART.SET_PASSWORD_SHOW>",
	HIDE:          "<TMPL_VAR MGISMART.SET_PASSWORD_HIDE>"
};

var setErr = {
	UI_EXTRA_ENV_INVALID:  "<TMPL_VAR MGISMART.UI_EXTRA_ENV_INVALID>",
	UI_EXTRA_ENV_CONFLICT: "<TMPL_VAR MGISMART.UI_EXTRA_ENV_CONFLICT>",
	UI_SAVE_FAILED:        "<TMPL_VAR MGISMART.UI_SAVE_FAILED>",
	UI_PIN_REQUIRED:       "<TMPL_VAR MGISMART.UI_PIN_REQUIRED>",
	UI_POST_REQUIRED:      "<TMPL_VAR MGISMART.UI_POST_REQUIRED>",
	UI_UNKNOWN_ACTION:     "<TMPL_VAR MGISMART.UI_UNKNOWN_ACTION>",
	UI_AJAX_FAILED:        "<TMPL_VAR MGISMART.UI_AJAX_FAILED>"
};

function setTogglePassword() {
	var field = document.getElementById("set-password");
	var icon  = $("#set-password-toggle i");
	if (field.type === "password") {
		field.type = "text";
		icon.removeClass("pi-eye").addClass("pi-eye-slash");
		$("#set-password-toggle").attr("title", setMsg.HIDE);
	} else {
		field.type = "password";
		icon.removeClass("pi-eye-slash").addClass("pi-eye");
		$("#set-password-toggle").attr("title", setMsg.SHOW);
	}
}

function setLoad() {
	$.ajax({ url: "ajax.cgi", type: "POST", dataType: "json", data: { action: "config-get", secpin: mgiPin } })
		.done(function(data) {
			if (!data || !data.ok || !data.config) { return; }
			var c = data.config;
			$("#set-user").val(c.saic_user || "");
			$("#set-password").val(c.saic_password || "");
			$("#set-region").val(c.saic_region || "eu");
			$("#set-countrycode").val(c.saic_phone_country_code || "");
			$("#set-topic").val(c.mqtt_topic || "saic");
			$("#set-hadiscovery").prop("checked", !!Number(c.ha_discovery_enabled));
			$("#set-allowdots").prop("checked", !!Number(c.mqtt_allow_dots_in_topic));
			$("#set-refreshinactive").val(c.refresh_period_inactive || "");
			$("#set-refreshactive").val(c.refresh_period_active || "");
			$("#set-refreshshutdown").val(c.refresh_period_after_shutdown || "");
			$("#set-refreshgrace").val(c.refresh_period_inactive_grace || "");
			$("#set-relogin").val(c.saic_relogin_delay || "");
			$("#set-messages").val(c.messages_request_interval || "");
			$("#set-accountrefresh").val(c.account_refresh_interval || "");
			$("#set-chargemin").val(c.charge_min_percentage || "");
			$("#set-battery").val(c.battery_capacity_mapping || "");
			$("#set-timezone").val(c.saic_user_timezone || "");
			$("#set-extraenv").val(c.extra_env || "");
			$("#set-loglevel").text(data.log_level || "");
		});
}

function setSave() {
	var payload = {
		saic_user:                 $("#set-user").val(),
		saic_password:             $("#set-password").val(),
		saic_region:               $("#set-region").val(),
		saic_phone_country_code:   $("#set-countrycode").val(),
		mqtt_topic:                $("#set-topic").val(),
		ha_discovery_enabled:      $("#set-hadiscovery").prop("checked") ? 1 : 0,
		mqtt_allow_dots_in_topic:  $("#set-allowdots").prop("checked") ? 1 : 0,
		refresh_period_inactive:       $("#set-refreshinactive").val(),
		refresh_period_active:         $("#set-refreshactive").val(),
		refresh_period_after_shutdown: $("#set-refreshshutdown").val(),
		refresh_period_inactive_grace: $("#set-refreshgrace").val(),
		saic_relogin_delay:        $("#set-relogin").val(),
		messages_request_interval: $("#set-messages").val(),
		account_refresh_interval:  $("#set-accountrefresh").val(),
		charge_min_percentage:     $("#set-chargemin").val(),
		battery_capacity_mapping:  $("#set-battery").val(),
		saic_user_timezone:        $("#set-timezone").val(),
		extra_env:                 $("#set-extraenv").val()
	};

	gwStatusLine("#set-savinghint", setMsg.SAVING, "info");
	$.ajax({
		url: "ajax.cgi", type: "POST", dataType: "json",
		data: { action: "config-set", config: JSON.stringify(payload), secpin: mgiPin }
	})
		.done(function(data) {
			if (data && data.ok) {
				gwStatusLine("#set-savinghint", setMsg.SAVED_RESTART, "ok");
				return;
			}
			var message = (data && data.error_key && setErr[data.error_key]) || setMsg.SAVING_FAILED;
			if (data && data.detail) { message += " (" + data.detail + ")"; }
			gwStatusLine("#set-savinghint", message, "error");
		})
		.fail(function() { gwStatusLine("#set-savinghint", setMsg.SAVING_FAILED, "error"); });
}

// =============================================================== UPDATE TAB

var upgText = {
	NOVERSION:  "<TMPL_VAR MGISMART.UPG_MSG_NOVERSION>",
	AVAILABLE:  "<TMPL_VAR MGISMART.UPG_HINT_AVAILABLE>",
	UPTODATE:   "<TMPL_VAR MGISMART.UPG_HINT_UPTODATE>",
	NOVERHINT:  "<TMPL_VAR MGISMART.UPG_HINT_NOVERSION>",
	NOTINST:    "<TMPL_VAR MGISMART.UPG_HINT_NOTINSTALLED>",
	CHECKING:   "<TMPL_VAR MGISMART.UPG_HINT_CHECKING>",
	UPGRADING:  "<TMPL_VAR MGISMART.UPG_HINT_UPGRADING>",
	OK:         "<TMPL_VAR MGISMART.UPG_HINT_OK>",
	ERROR:      "<TMPL_VAR MGISMART.UPG_HINT_ERROR>",
	INSTALL:    "<TMPL_VAR MGISMART.UPG_BUTTON_INSTALL>",
	UPDATE:     "<TMPL_VAR MGISMART.UPG_BUTTON>"
};

// Loads the installed and available versions. "force" bypasses the cached
// GitHub answer, which is what the "check now" button is for; the automatic
// load on tab open uses the cache so opening the tab never spends API quota.
function upgVersions(force) {
	$("#upg-current, #upg-available").text("…");
	if (force) { gwStatusLine("#upg-version-hint", upgText.CHECKING, "info"); }
	$("#upg-check-btn").prop("disabled", true);

	$.ajax({
		url: "ajax.cgi",
		type: force ? "POST" : "GET",
		dataType: "json",
		data: { action: force ? "version-refresh" : "version-info" }
	})
		.done(function(data) {
			$("#upg-check-btn").prop("disabled", false);
			if (!data || !data.ok) { gwStatusLine("#upg-version-hint", upgText.NOVERHINT, "error"); return; }

			$("#upg-current").text(data.current || upgText.NOVERSION);
			$("#upg-available").text(data.available || upgText.NOVERSION);
			$("#upg-channel").val(data.channel || "release");
			$("#upg-btn").text(data.installed ? upgText.UPDATE : upgText.INSTALL);

			if (data.update_available) {
				$("#upg-btn").prop("disabled", false);
				gwStatusLine("#upg-version-hint", data.installed ? upgText.AVAILABLE : upgText.NOTINST, "info");
			} else {
				$("#upg-btn").prop("disabled", true);
				var known = data.current && data.available;
				gwStatusLine("#upg-version-hint", known ? upgText.UPTODATE : upgText.NOVERHINT, known ? "ok" : "error");
			}
		})
		.fail(function() {
			$("#upg-check-btn").prop("disabled", false);
			gwStatusLine("#upg-version-hint", upgText.NOVERHINT, "error");
		});
}

// The channel is a stored setting, so switching it saves and then re-reads the
// versions - the cache is keyed by channel and misses on its own.
function upgChannelChange() {
	$.ajax({
		url: "ajax.cgi", type: "POST", dataType: "json",
		data: { action: "set-channel", channel: $("#upg-channel").val() }
	})
		.always(function() { upgVersions(true); });
}

// Runs the update. Building the venv takes minutes on a Raspberry Pi, far
// longer than a web request may last, so the server detaches the run and this
// polls for the outcome. The button stays disabled throughout so it cannot be
// started twice; the gateway is restarted by the update itself.
function upgradeGateway() {
	if ($("#upg-btn").prop("disabled")) { return; }
	$("#upg-btn").prop("disabled", true);
	$("#upg-check-btn").prop("disabled", true);
	gwStatusLine("#upg-status", upgText.UPGRADING, "info");

	$.ajax({ url: "ajax.cgi", type: "POST", dataType: "json", data: { action: "update-run" } })
		.done(function(data) {
			if (data && data.ok) { upgPoll(0); }
			else { upgFinished(false); }
		})
		.fail(function() { upgFinished(false); });
}

// Polls the detached update for up to about 20 minutes.
function upgPoll(attempt) {
	if (attempt > 400) { upgFinished(false); return; }
	window.setTimeout(function() {
		$.ajax({ url: "ajax.cgi", type: "GET", dataType: "json", data: { action: "update-status" } })
			.done(function(data) {
				if (!data || !data.ok) { upgFinished(false); return; }
				if (data.running) { upgPoll(attempt + 1); return; }
				if (data.finished) { upgFinished(!!data.success); return; }
				// Neither running nor a result yet: the child may not have been
				// scheduled at all. Give it a few more rounds before giving up.
				if (attempt < 5) { upgPoll(attempt + 1); } else { upgFinished(false); }
			})
			.fail(function() { upgPoll(attempt + 1); });
	}, 3000);
}

function upgFinished(ok) {
	gwStatusLine("#upg-status", ok ? upgText.OK : upgText.ERROR, ok ? "ok" : "error");
	$("#upg-check-btn").prop("disabled", false);
	upgVersions(false);
}

</script>

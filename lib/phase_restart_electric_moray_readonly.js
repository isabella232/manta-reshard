/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/.
 */

/*
 * Copyright (c) 2018, Joyent, Inc.
 */


var mod_vasync = require('vasync');

var lib_common = require('../lib/common');
var lib_electric_moray = require('../lib/electric_moray');


function
phase_restart_electric_moray_readonly(ctl)
{
	var insts;
	var status = ctl.status();

	mod_vasync.waterfall([ function (done) {
		if (ctl.pausing(done)) {
			return;
		}

		ctl.get_instances({ service: 'electric-moray' }, status,
		    function (err, _insts) {
			if (err) {
				done(err);
				return;
			}

			insts = _insts;
			done();
		});

	}, function (done) {
		if (ctl.pausing(done)) {
			return;
		}

		/*
		 * Restart instances in a stable order.  That way, if the
		 * reshard server restarts repeatedly, it won't randomly
		 * clobber disjoint sets of instances.
		 */
		var ilist = Object.keys(insts).sort();

		status.update('restarting all %d Electric Moray instances',
		    ilist.length);
		ctl.log.info({ instances: ilist },
		    'restarting all Electric Moray instances');

		/*
		 * Restart at most one third of the Electric Moray instances at
		 * one time.
		 */
		var concurrency = Math.floor(ilist.length / 3);
		if (concurrency < 1) {
			concurrency = 1;
		}

		var stchs = {};

		lib_common.parallel(ctl, { inputs: ilist,
		    concurrency: concurrency,
		    retry_delay: 15 * 1000,
		    func: function (uuid, idx, next) {
			if (ctl.pausing(next)) {
				return;
			}

			if (!stchs[uuid]) {
				stchs[uuid] = status.child();
			}
			var stch = stchs[uuid];

			stch.update('zone %s (%d/%d)', uuid, idx, ilist.length);
			ctl.log.info('restarting Electric Moray in zone ' +
			    '"%s"', uuid);

			lib_electric_moray.em_restart_one(ctl, uuid,
			    ensure_shards_are_read_only, stch, function (err) {
				stch.trunc();
				if (err) {
					stch.child().update(
					    'failed: %s (retrying)',
					    err.message);
				} else {
					stch.child().update('ok');
				}
				next(err);
			});
		}}, done);

	} ], function (err) {
		if (err) {
			ctl.retry(err);
			return;
		}

		ctl.finish();
	});
}

/*
 * Check the index map for this Electric Moray instance, verifying that both
 * the existing shard and the new shard are present, and are marked read-only.
 * If either shard is missing, or not marked read-only, return false to signify
 * that a configuration update is required.
 */
function
ensure_shards_are_read_only(ctl, lookup_shard)
{
	var p = ctl.plan();

	var s;
	var old_readonly = false;
	if ((s = lookup_shard(p.shard)) !== null && s.readOnly) {
		old_readonly = true;
	}

	var new_readonly = false;
	if ((s = lookup_shard(p.new_shard)) !== null && s.readOnly) {
		new_readonly = true;
	}

	return (old_readonly && new_readonly);
}


module.exports = {
	phase_restart_electric_moray_readonly:
	    phase_restart_electric_moray_readonly,
};

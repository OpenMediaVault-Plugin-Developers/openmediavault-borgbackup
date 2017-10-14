/**
 * @license   http://www.gnu.org/licenses/gpl.html GPL Version 3
 * @author    Volker Theile <volker.theile@openmediavault.org>
 * @author    OpenMediaVault Plugin Developers <plugins@omv-extras.org>
 * @copyright Copyright (c) 2009-2013 Volker Theile
 * @copyright Copyright (c) 2013-2017 OpenMediaVault Plugin Developers
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program. If not, see <http://www.gnu.org/licenses/>.
 */
// require('js/omv/PluginManager.js')
// require('js/omv/module/admin/diagnostic/log/plugin/Plugin.js')
// require('js/omv/util/Format.js')

Ext.define('OMV.module.admin.diagnostic.log.plugin.BorgBackup', {
    extend: 'OMV.module.admin.diagnostic.log.plugin.Plugin',
    alias: 'omv.plugin.diagnostic.log.borgbackup',

    id: 'borgbackup',
    text: _('BorgBackup'),
    stateful: true,
    stateId: 'a4f1290c-b0e5-11e7-8bd2-ff8e9c7edca4',
    columns: [{
        text: _('Date & Time'),
        sortable: true,
        dataIndex: 'date',
        stateId: 'date',
        flex: 1
    },{
        text: _('Component'),
        sortable: true,
        dataIndex: 'component',
        stateId: 'component',
        flex: 1
    },{
        text: _('Level'),
        sortable: true,
        dataIndex: 'level',
        stateId: 'level',
        flex: 1
    },{
        text: _('Message'),
        sortable: true,
        dataIndex: 'message',
        stateId: 'message',
        flex: 1
    }],
    rpcParams: {
        id: 'borgbackup'
    },
    rpcFields: [
        { name: 'date', type: 'string' },
        { name: 'component', type: 'string' },
        { name: 'level', type: 'string' },
        { name: 'message', type: 'string' },
    ]
});

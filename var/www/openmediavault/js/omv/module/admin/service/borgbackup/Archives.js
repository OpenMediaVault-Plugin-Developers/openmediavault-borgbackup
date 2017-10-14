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
// require('js/omv/WorkspaceManager.js')
// require('js/omv/workspace/grid/Panel.js')
// require('js/omv/workspace/window/Form.js')
// require('js/omv/workspace/window/plugin/ConfigObject.js')
// require('js/omv/util/Format.js')
// require('js/omv/Rpc.js')
// require('js/omv/data/Store.js')
// require('js/omv/data/Model.js')
// require('js/omv/data/proxy/Rpc.js')

Ext.define('OMV.module.admin.service.borgbackup.Archive', {
    extend: 'OMV.workspace.window.Form',
    requires: [
        'OMV.workspace.window.plugin.ConfigObject'
    ],

    width: 500,

    rpcService: 'BorgBackup',
    rpcGetMethod: 'getArchive',
    rpcSetMethod: 'setArchive',
    plugins: [{
        ptype: 'configobject'
    }],

    getFormItems: function() {
        var me = this;
        return [{
            xtype: 'textfield',
            name: 'name',
            fieldLabel: _('Name'),
            allowBlank: false
        },{
            xtype: 'combo',
            name: 'reporef',
            fieldLabel: _('Repo'),
            emptyText: _('Select a repo ...'),
            editable: false,
            triggerAction: 'all',
            displayField: 'name',
            valueField: 'uuid',
            allowNone: true,
            allowBlank: true,
            store: Ext.create('OMV.data.Store', {
                autoLoad: true,
                model: OMV.data.Model.createImplicit({
                    idProperty: 'uuid',
                    fields: [
                        { name: 'uuid', type: 'string' },
                        { name: 'name', type: 'string' }
                    ]
                }),
                proxy : {
                    type: 'rpc',
                    rpcData: {
                        service: 'BorgBackup',
                        method: 'enumerateRepoCandidates'
                    },
                    appendSortParams : false
                },
                sorters : [{
                    direction : 'ASC',
                    property  : 'name'
                }]
            })
        },{
            xtype: 'combo',
            name: 'compressiontype',
            fieldLabel: _('Compression Type'),
            queryMode: 'local',
            store: [
                [ 'none', _('None') ],
                [ 'lz4', _('lz4 - super fast, low compression') ],
                [ 'zlib', _('zlib - less fast, higher compression') ],
                [ 'lzma', _('lzma - even slower, even higher compression') ]
            ],
            allowBlank: false,
            editable: false,
            triggerAction: 'all',
            value: 'none'
        },{
            xtype: 'numberfield',
            name: 'compressionratio',
            fieldLabel: _('Compression Ratio'),
            minValue: 0,
            maxValue: 9,
            allowDecimals: false,
            allowBlank: false,
            value: 9,
            plugins: [{
                ptype: 'fieldinfo',
                text: _('0 is the fastest compression and 9 is the best compression')
            }]
        },{
            xtype: 'checkbox',
            name: 'onefs',
            fieldLabel: _('One Filesystem'),
            checked: false
        },{
            xtype: 'checkbox',
            name: 'noatime',
            fieldLabel: _('No atime'),
            checked: false
        },{
            xtype: 'textfield',
            name: 'include',
            fieldLabel: _('Includes'),
            allowBlank: false,
            plugins: [{
                ptype: 'fieldinfo',
                text: _('Put comma between each directory')
            }]
        },{
            xtype: 'textfield',
            name: 'exclude',
            fieldLabel: _('Excludes'),
            allowBlank: true,
            plugins: [{
                ptype: 'fieldinfo',
                text: _('Put comma between each directory')
            }]
        }];
    }
});

Ext.define('OMV.module.admin.service.borgbackup.Archives', {
    extend: 'OMV.workspace.grid.Panel',
    requires: [
        'OMV.Rpc',
        'OMV.data.Store',
        'OMV.data.Model',
        'OMV.data.proxy.Rpc',
        'OMV.util.Format'
    ],
    uses: [
        'OMV.module.admin.service.borgbackup.Archive'
    ],

    hideEditButton: true,
    hidePagingToolbar: false,
    stateful: true,
    stateId: 'bdef0cfa-b0ed-11e7-ba14-1b4b82806d9d',
    columns: [{
        xtype: 'textcolumn',
        text: _('Name'),
        sortable: true,
        dataIndex: 'name',
        stateId: 'name'
    }],

    initComponent: function() {
        var me = this;
        Ext.apply(me, {
            store: Ext.create('OMV.data.Store', {
                autoLoad: true,
                model: OMV.data.Model.createImplicit({
                    idProperty: 'uuid',
                    fields: [
                        { name: 'uuid', type: 'string' },
                        { name: 'name', type: 'string' }
                    ]
                }),
                proxy: {
                    type: 'rpc',
                    rpcData: {
                        service: 'BorgBackup',
                        method: 'getArchiveList'
                    }
                }
            })
        });
        me.callParent(arguments);
    },

    onAddButton: function() {
        var me = this;
        Ext.create('OMV.module.admin.service.borgbackup.Archive', {
            title: _('Add archive'),
            uuid: OMV.UUID_UNDEFINED,
            listeners: {
                scope: me,
                submit: function() {
                    this.doReload();
                }
            }
        }).show();
    },

    doDeletion: function(record) {
        var me = this;
        OMV.Rpc.request({
            scope: me,
            callback: me.onDeletion,
            rpcData: {
                service: 'BorgBackup',
                method: 'deleteArchive',
                params: {
                    uuid: record.get('uuid')
                }
            }
        });
    }
});

OMV.WorkspaceManager.registerPanel({
    id: 'archives',
    path: '/service/borgbackup',
    text: _('Archives'),
    position: 20,
    className: 'OMV.module.admin.service.borgbackup.Archives'
});

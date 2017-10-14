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
// require('js/omv/Rpc.js')
// require('js/omv/data/Store.js')
// require('js/omv/data/Model.js')
// require('js/omv/data/proxy/Rpc.js')
// require('js/omv/form/field/SharedFolderComboBox.js')

Ext.define('OMV.module.admin.service.borgbackup.Repo', {
    extend: 'OMV.workspace.window.Form',
    uses: [
        'OMV.form.field.SharedFolderComboBox',
        'OMV.workspace.window.plugin.ConfigObject'
    ],

    rpcService: 'BorgBackup',
    rpcGetMethod: 'getRepo',
    rpcSetMethod: 'setRepo',
    plugins: [{
        ptype: 'configobject'
    }],

    getFormConfig: function() {
        return {
            plugins: [{
                ptype: 'linkedfields',
                correlations: [{
                    name: 'sharedfolderref',
                    conditions: [
                        { name: 'type', value: 'local' }
                    ],
                    properties: [
                        'show',
                        '!allowBlank'
                    ]
                },{
                    name: 'uri',
                    conditions: [
                        { name: 'type', value: 'remote' }
                    ],
                    properties: [
                        'show',
                        '!allowBlank'
                    ]
                }]
            }]
        };
    },

    getFormItems: function () {
        var me = this;
        return [{
            xtype: 'textfield',
            name: 'name',
            fieldLabel: _('Name'),
            allowBlank: false
        },{
            xtype: 'combo',
            name: 'type',
            fieldLabel: _('Type'),
            queryMode: 'local',
            store: [
                [ 'local', _('Local') ],
                [ 'remote', _('Remote') ]
            ],
            allowBlank: false,
            editable: false,
            triggerAction: 'all',
            value: 'local'
        },{
            xtype: 'sharedfoldercombo',
            name: 'sharedfolderref',
            fieldLabel: _('Shared Folder')
        },{
            xtype: 'textfield',
            name: 'uri',
            fieldLabel: _('Remote Path'),
            allowBlank: true,
            hidden: true,
            plugins: [{
                ptype: 'fieldinfo',
                text: _('Must have ssh keys setup.  Remote path should be in the form:  user@hostname:path')
            }]
        },{
            xtype: 'passwordfield',
            name: 'passphrase',
            fieldLabel: _('Passphrase'),
            value: ''
        },{
            xtype: 'checkbox',
            name: 'encryption',
            fieldLabel: _('Encryption'),
            checked: false
        }];
    }
});

Ext.define('OMV.module.admin.service.borgbackup.RepoList', {
    extend: 'OMV.workspace.grid.Panel',
    requires: [
        'OMV.Rpc',
        'OMV.data.Store',
        'OMV.data.Model',
        'OMV.data.proxy.Rpc'
    ],
    uses: [
        'OMV.module.admin.service.borgbackup.Repo'
    ],

    hideEditButton: true,
    hidePagingToolbar: false,
    stateful: true,
    stateId: 'bce5761c-b0e0-11e7-993b-27be4a786741',
    columns: [{
        xtype: 'textcolumn',
        text: _('Name'),
        sortable: true,
        dataIndex: 'name',
        stateId: 'name'
    },{
        xtype: 'textcolumn',
        text: _('Shared Folder'),
        sortable: true,
        dataIndex: 'sharedfoldername',
        stateId: 'sharedfoldername'
    },{
        xtype: 'textcolumn',
        text: _('Remote Path'),
        sortable: true,
        dataIndex: 'uri',
        stateId: 'uri'
    },{
        xtype: 'booleaniconcolumn',
        header: _('Encryption'),
        sortable: true,
        dataIndex: 'encryption',
        align: 'center',
        width: 100,
        resizable: false,
        trueIcon: 'switch_on.png',
        falseIcon: 'switch_off.png'
    }],

    initComponent: function () {
        var me = this;
        Ext.apply(me, {
            store: Ext.create('OMV.data.Store', {
                autoLoad: true,
                model: OMV.data.Model.createImplicit({
                    idProperty: 'uuid',
                    fields: [
                        { name: 'uuid', type: 'string' },
                        { name: 'name', type: 'string' },
                        { name: 'sharedfoldername', type: 'string' },
                        { name: 'uri', type: 'string' },
                        { name: 'encryption', type: 'boolean' }
                    ]
                }),
                proxy: {
                    type: 'rpc',
                    rpcData: {
                        service: 'BorgBackup',
                        method: 'getRepoList'
                    }
                }
            })
        });
        me.callParent(arguments);
    },

    onAddButton: function () {
        var me = this;
        Ext.create('OMV.module.admin.service.borgbackup.Repo', {
            title: _('Add repo'),
            uuid: OMV.UUID_UNDEFINED,
            listeners: {
                scope: me,
                submit: function () {
                    this.doReload();
                }
            }
        }).show();
    },

    doDeletion: function (record) {
        var me = this;
        OMV.Rpc.request({
            scope: me,
            callback: me.onDeletion,
            rpcData: {
                service: 'BorgBackup',
                method: 'deleteRepo',
                params: {
                    uuid: record.get('uuid')
                }
            }
        });
    }
});

OMV.WorkspaceManager.registerPanel({
    id        : 'contents',
    path      : '/service/borgbackup',
    text      : _('Repos'),
    position  : 10,
    className : 'OMV.module.admin.service.borgbackup.RepoList'
});

/**
 * @license   http://www.gnu.org/licenses/gpl.html GPL Version 3
 * @author    Volker Theile <volker.theile@openmediavault.org>
 * @author    OpenMediaVault Plugin Developers <plugins@omv-extras.org>
 * @copyright Copyright (c) 2009-2013 Volker Theile
 * @copyright Copyright (c) 2013-2020 OpenMediaVault Plugin Developers
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
// require("js/omv/WorkspaceManager.js")
// require("js/omv/workspace/grid/Panel.js")
// require("js/omv/workspace/window/Form.js")
// require("js/omv/workspace/window/plugin/ConfigObject.js")
// require("js/omv/util/Format.js")
// require("js/omv/Rpc.js")
// require("js/omv/data/Store.js")
// require("js/omv/data/Model.js")
// require("js/omv/data/proxy/Rpc.js")

Ext.define("OMV.module.admin.service.borgbackup.Archive", {
    extend: "OMV.workspace.window.Form",
    requires: [
        "OMV.workspace.window.plugin.ConfigObject"
    ],

    width: 500,

    rpcService: "BorgBackup",
    rpcGetMethod: "getArchive",
    rpcSetMethod: "setArchive",
    plugins: [{
        ptype: "configobject"
    }],

    getFormItems: function() {
        var me = this;
        return [{
            xtype: "checkbox",
            name: "enable",
            fieldLabel: _("Enable"),
            checked: true
        },{
            xtype: "textfield",
            name: "name",
            fieldLabel: _("Name/Prefix"),
            allowBlank: false,
            maskRe: new RegExp("[a-zA-Z1-9_`]+$"),
            plugins: [{
                ptype: "fieldinfo",
                text: _("Uses value as prefix for archive name.")
            }]
        },{
            xtype: "combo",
            name: "reporef",
            fieldLabel: _("Repo"),
            emptyText: _("Select a repo ..."),
            editable: false,
            triggerAction: "all",
            displayField: "name",
            valueField: "uuid",
            allowNone: true,
            allowBlank: true,
            store: Ext.create("OMV.data.Store", {
                autoLoad: true,
                model: OMV.data.Model.createImplicit({
                    idProperty: "uuid",
                    fields: [
                        { name: "uuid", type: "string" },
                        { name: "name", type: "string" }
                    ]
                }),
                proxy : {
                    type: "rpc",
                    rpcData: {
                        service: "BorgBackup",
                        method: "enumerateRepoCandidates"
                    },
                    appendSortParams : false
                },
                sorters : [{
                    direction : "ASC",
                    property  : "name"
                }]
            })
        },{
            xtype: "combo",
            name: "compressiontype",
            fieldLabel: _("Compression Type"),
            queryMode: "local",
            store: [
                [ "none", _("None") ],
                [ "zstd", _("zstd - super fast, medium compression") ],
                [ "lz4", _("lz4 - super fast, low compression") ],
                [ "zlib", _("zlib - less fast, higher compression") ],
                [ "lzma", _("lzma - even slower, even higher compression") ]
            ],
            allowBlank: false,
            editable: false,
            triggerAction: "all",
            value: "none"
        },{
            xtype: "numberfield",
            name: "compressionratio",
            fieldLabel: _("Compression Ratio"),
            minValue: 0,
            maxValue: 9,
            allowDecimals: false,
            allowBlank: false,
            value: 9,
            plugins: [{
                ptype: "fieldinfo",
                text: _("0 is the fastest compression and 9 is the best compression")
            }]
        },{
            xtype: "checkbox",
            name: "onefs",
            fieldLabel: _("One Filesystem"),
            checked: false
        },{
            xtype: "checkbox",
            name: "noatime",
            fieldLabel: _("No atime"),
            checked: false
        },{
            xtype: "textfield",
            name: "include",
            fieldLabel: _("Includes"),
            allowBlank: false,
            plugins: [{
                ptype: "fieldinfo",
                text: _("Put comma between each directory")
            }]
        },{
            xtype: "textfield",
            name: "exclude",
            fieldLabel: _("Excludes"),
            allowBlank: true,
            plugins: [{
                ptype: "fieldinfo",
                text: _("Put comma between each directory.")
            }]
        },{
            xtype: "numberfield",
            name: "hourly",
            fieldLabel: _("Hourly"),
            minValue: 0,
            allowDecimals: false,
            allowBlank: false,
            value: 0,
            plugins: [{
                ptype: "fieldinfo",
                text: _("Number of hourly archives to keep.")
            }]
        },{
            xtype: "numberfield",
            name: "daily",
            fieldLabel: _("Daily"),
            minValue: 0,
            allowDecimals: false,
            allowBlank: false,
            value: 7,
            plugins: [{
                ptype: "fieldinfo",
                text: _("Number of daily archives to keep.")
            }]
        },{
            xtype: "numberfield",
            name: "weekly",
            fieldLabel: _("Weekly"),
            minValue: 0,
            allowDecimals: false,
            allowBlank: false,
            value: 4,
            plugins: [{
                ptype: "fieldinfo",
                text: _("Number of weekly archives to keep.")
            }]
        },{
            xtype: "numberfield",
            name: "monthly",
            fieldLabel: _("Monthly"),
            minValue: 0,
            allowDecimals: false,
            allowBlank: false,
            value: 3,
            plugins: [{
                ptype: "fieldinfo",
                text: _("Number of monthly archives to keep.")
            }]
        },{
            xtype: "numberfield",
            name: "yearly",
            fieldLabel: _("Yearly"),
            minValue: 0,
            allowDecimals: false,
            allowBlank: false,
            value: 0,
            plugins: [{
                ptype: "fieldinfo",
                text: _("Number of yearly archives to keep.")
            }]
        },{
            xtype: "numberfield",
            name: "ratelimit",
            fieldLabel: _("Rate limit"),
            minValue: 0,
            allowDecimals: false,
            allowBlank: false,
            value: 0,
            plugins: [{
                ptype: "fieldinfo",
                text: _("Set remote network upload rate limit in kiByte/s (default: 0=unlimited).")
            }]
        },{
            xtype: "checkbox",
            name: "list",
            fieldLabel: _("List"),
            checked: true,
            boxLabel: _("Output verbose list of files and directories.")
        }];
    }
});

Ext.define("OMV.module.admin.service.borgbackup.Archives", {
    extend: "OMV.workspace.grid.Panel",
    requires: [
        "OMV.Rpc",
        "OMV.data.Store",
        "OMV.data.Model",
        "OMV.data.proxy.Rpc",
        "OMV.util.Format"
    ],
    uses: [
        "OMV.module.admin.service.borgbackup.Archive"
    ],

    hidePagingToolbar: false,
    stateful: true,
    stateId: "bdef0cfa-b0ed-11e7-ba14-1b4b82806d9d",
    columns: [{
        xtype: "booleaniconcolumn",
        text: _("Enabled"),
        sortable: true,
        dataIndex: "enable",
        stateId: "enable",
        align: "center",
        width: 80,
        resizable: false,
        trueIcon: "switch_on.png",
        falseIcon: "switch_off.png"
    },{
        xtype: "textcolumn",
        text: _("Name"),
        sortable: true,
        dataIndex: "name",
        stateId: "name"
    },{
        xtype: "textcolumn",
        text: _("Repo"),
        sortable: true,
        dataIndex: "reponame",
        stateId: "reponame"
    },{
        xtype: "textcolumn",
        text: _("Compression"),
        sortable: true,
        dataIndex: "compressiontype",
        stateId: "compressiontype"
    },{
        xtype: "textcolumn",
        text: _("Includes"),
        sortable: true,
        dataIndex: "include",
        stateId: "include",
        flex: 1
    },{
        xtype: "textcolumn",
        text: _("Excludes"),
        sortable: true,
        dataIndex: "exclude",
        stateId: "exclude",
        flex: 1
    }],

    getTopToolbarItems: function() {
        var me = this;
        var items = me.callParent(arguments);

        Ext.Array.insert(items, 3, [{
            xtype: "button",
            text: _("Run"),
            icon: "images/play.png",
            handler: Ext.Function.bind(me.onRunButton, me, [ me ]),
            scope: me,
            disabled: true,
            selectionConfig: {
                minSelections: 1,
                maxSelections: 1
            }
        }]);
        return items;
    },

    initComponent: function() {
        var me = this;
        Ext.apply(me, {
            store: Ext.create("OMV.data.Store", {
                autoLoad: true,
                model: OMV.data.Model.createImplicit({
                    idProperty: "uuid",
                    fields: [
                        { name: "uuid", type: "string" },
                        { name: "enable", type: "boolean" },
                        { name: "name", type: "string" },
                        { name: "reponame", type: "string" },
                        { name: "compressiontype", type: "string" },
                        { name: "include", type: "string" },
                        { name: "exclude", type: "string" }
                    ]
                }),
                proxy: {
                    type: "rpc",
                    rpcData: {
                        service: "BorgBackup",
                        method: "getArchiveList"
                    }
                }
            })
        });
        me.callParent(arguments);
    },

    doDeletion: function(record) {
        var me = this;
        OMV.Rpc.request({
            scope: me,
            callback: me.onDeletion,
            rpcData: {
                service: "BorgBackup",
                method: "deleteArchive",
                params: {
                    uuid: record.get("uuid")
                }
            }
        });
    },

    onAddButton: function() {
        var me = this;
        Ext.create("OMV.module.admin.service.borgbackup.Archive", {
            title: _("Add archive"),
            uuid: OMV.UUID_UNDEFINED,
            listeners: {
                scope: me,
                submit: function() {
                    this.doReload();
                }
            }
        }).show();
    },

    onEditButton: function () {
        var me = this;
        var record = me.getSelected();
        Ext.create("OMV.module.admin.service.borgbackup.Archive", {
            title: _("Edit archive"),
            uuid: record.get("uuid"),
            listeners: {
                scope: me,
                submit: function () {
                    this.doReload();
                }
            }
        }).show();
    },

    onCmdButton : function(command) {
        var me = this;
        var record = me.getSelected();
        var wnd = Ext.create("OMV.window.Execute", {
            title: _("Checking ") + record.get("name") + " ...",
            rpcService: "BorgBackup",
            rpcMethod: "archiveCommand",
            rpcParams: {
                "command": command,
                "uuid": record.get("uuid")
            },
            rpcIgnoreErrors: true,
            hideStartButton: true,
            hideStopButton: true,
            listeners: {
                scope: me,
                finish: function(wnd, response) {
                    wnd.appendValue(_("Done..."));
                    wnd.setButtonDisabled("close", false);
                },
                exception: function(wnd, error) {
                    OMV.MessageBox.error(null, error);
                    wnd.setButtonDisabled("close", false);
                }
            }
        });
        wnd.setButtonDisabled("close", true);
        wnd.show();
        wnd.start();
    },

    onRunButton : function() {
        var me = this;
        var record = me.getSelected();
        var title = _("Create archive for ") + record.get("name") + " ...";
        var wnd = Ext.create("OMV.window.Execute", {
            title: title,
            rpcService: "BorgBackup",
            rpcMethod: "createArchive",
            rpcParams: {
                "uuid": record.get("uuid")
            },
            rpcIgnoreErrors: true,
            hideStartButton: true,
            hideStopButton: true,
            listeners: {
                scope: me,
                finish: function(wnd, response) {
                    wnd.appendValue(_("Done..."));
                    wnd.setButtonDisabled("close", false);
                },
                exception: function(wnd, error) {
                    OMV.MessageBox.error(null, error);
                    wnd.setButtonDisabled("close", false);
                },
                close: function() {
                    this.doReload();
                }
            }
        });
        wnd.setButtonDisabled("close", true);
        wnd.show();
        wnd.start();
    }
});

OMV.WorkspaceManager.registerPanel({
    id: "archives",
    path: "/service/borgbackup",
    text: _("Archives"),
    position: 20,
    className: "OMV.module.admin.service.borgbackup.Archives"
});

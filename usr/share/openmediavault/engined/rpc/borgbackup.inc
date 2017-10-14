<?php
/*
 * @author    Volker Theile <volker.theile@openmediavault.org>
 * @author    OpenMediaVault Plugin Developers <plugins@omv-extras.org>
 * @copyright Copyright (c) 2009-2013 Volker Theile
 * @copyright Copyright (c) 2013-2017 OpenMediaVault Plugin Developers
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program.  If not, see <http://www.gnu.org/licenses/>.
 */

require_once("openmediavault/functions.inc");

class OMVRpcServiceBorgBackup extends \OMV\Rpc\ServiceAbstract
{
    private $getProgram = "/usr/bin/borg";
    private $getLogFile = "/var/log/borgbackup.log";

    public function getName()
    {
        return 'BorgBackup';
    }

    public function initialize()
    {
        $this->registerMethod('getRepoList');
        $this->registerMethod('getRepo');
        $this->registerMethod('setRepo');
        $this->registerMethod('deleteRepo');

        $this->registerMethod('getArchiveList');
        $this->registerMethod('getArchive');
        $this->registerMethod('setArchive');
        $this->registerMethod('deleteArchive');

        $this->registerMethod('executeCommand');
    }

    public function getRepoList($params, $context)
    {
        // Validate the RPC caller context.
        $this->validateMethodContext($context, ["role" => OMV_ROLE_ADMINISTRATOR]);
        // Validate the parameters of the RPC service method.
        $this->validateMethodParams($params, "rpc.common.getlist");
        // Get the configuration object.
        $db = \OMV\Config\Database::getInstance();
        $objects = $db->get("conf.service.borgbackup.repo");
        // Add additional share informations.
        $objectsAssoc = [];
        foreach ($objects as $objectk => &$objectv) {
            // Add the new property 'sharedfoldername'.
            $objectv->add("sharedfoldername", "string", gettext("n/a"));
            // Get the shared folder configuration object.
            $sfObject = $db->get("conf.system.sharedfolder",
                $objectv->get("sharedfolderref"));
            // Update the 'sharedfoldername' property.
            $objectv->set("sharedfoldername", $sfObject->get("name"));
            $objectsAssoc[] = $objectv->getAssoc();
        }
        // Filter the result.
        return $this->applyFilter($objectsAssoc, $params['start'], $params['limit'],
            $params['sortfield'], $params['sortdir']);
    }

    public function getRepo($params, $context)
    {
        // Validate the RPC caller context.
        $this->validateMethodContext($context, ["role" => OMV_ROLE_ADMINISTRATOR]);
        // Validate the parameters of the RPC service method.
        $this->validateMethodParams($params, "rpc.common.objectuuid");
        // Get the configuration object.
        $db = \OMV\Config\Database::getInstance();
        return $db->getAssoc("conf.service.borgbackup.repo", $params['uuid']);
    }

    public function setRepo($params, $context)
    {
        // Validate the RPC caller context.
        $this->validateMethodContext($context, ["role" => OMV_ROLE_ADMINISTRATOR]);
        // Validate the parameters of the RPC service method.
        $this->validateMethodParams($params, "rpc.borgbackup.setrepo");
        // Prepare the configuration object.
        $object = new \OMV\Config\ConfigObject("conf.service.borgbackup.repo");
        // Remove spaces from name
        $params['name'] = str_replace(" ", "_", $params['name']);
        $object->setAssoc($params);
        // Set the configuration object.
        $isNew = $object->isNew();
        $db = \OMV\Config\Database::getInstance();
        if (TRUE === $isNew) {
            // Check uniqueness - Shared folder
            $db->assertIsUnique($object, "name");
            $db->assertIsUnique($object, "sharedfolderref");
        }
        $db->set($object);
        // Return the configuration object.
        return $object->getAssoc();
    }

    public function deleteRepo($params, $context)
    {
        // Validate the RPC caller context.
        $this->validateMethodContext($context, ["role" => OMV_ROLE_ADMINISTRATOR]);
        // Validate the parameters of the RPC service method.
        $this->validateMethodParams($params, "rpc.common.objectuuid");
        // Delete the configuration object.
        $db = \OMV\Config\Database::getInstance();
        $object = $db->get("conf.service.borgbackup.repo", $params['uuid']);
        $db->delete($object);
        // Return the deleted configuration object.
        return $object->getAssoc();
    }

    public function getArchiveList($params, $context)
    {
        // Validate the RPC caller context.
        $this->validateMethodContext($context, ["role" => OMV_ROLE_ADMINISTRATOR]);
        // Validate the parameters of the RPC service method.
        $this->validateMethodParams($params, "rpc.common.getlist");
        // Get configuration data.
        $db = \OMV\Config\Database::getInstance();
        $objects = $db->getAssoc("conf.service.borgbackup.archive");
        // Filter the result.
        return $this->applyFilter($objects, $params['start'], $params['limit'],
            $params['sortfield'], $params['sortdir']);
    }

    public function getArchive($params, $context)
    {
        // Validate the RPC caller context.
        $this->validateMethodContext($context, ["role" => OMV_ROLE_ADMINISTRATOR]);
        // Validate the parameters of the RPC service method.
        $this->validateMethodParams($params, "rpc.common.objectuuid");
        // Get the configuration object.
        $db = \OMV\Config\Database::getInstance();
        return $db->getAssoc("conf.service.borgbackup.archive", $params['uuid']);
    }

    public function setArchive($params, $context)
    {
        // Validate the RPC caller context.
        $this->validateMethodContext($context, ["role" => OMV_ROLE_ADMINISTRATOR]);
        // Validate the parameters of the RPC service method.
        $this->validateMethodParams($params, "rpc.borgbackup.setarchive");
        // Prepare the configuration object.
        $object = new \OMV\Config\ConfigObject("conf.service.borgbackup.archive");
        // Remove spaces from name
        $params['name'] = str_replace(" ", "_", $params['name']);
        $object->setAssoc($params);
        // Set the configuration object.
        $isNew = $object->isNew();
        $db = \OMV\Config\Database::getInstance();
        if (TRUE === $isNew) {
            // Check uniqueness - Shared folder
            $db->assertIsUnique($object, "name");
        }
        $db->set($object);
        // Return the configuration object.
        return $object->getAssoc();
    }

    public function deleteArchive($params, $context)
    {
        // Validate the RPC caller context.
        $this->validateMethodContext($context, ["role" => OMV_ROLE_ADMINISTRATOR]);
        // Validate the parameters of the RPC service method.
        $this->validateMethodParams($params, "rpc.common.objectuuid");
        // Delete the configuration object.
        $db = \OMV\Config\Database::getInstance();
        $object = $db->get("conf.service.borgbackup.archive", $params['uuid']);
        $db->delete($object);
        // Return the deleted configuration object.
        return $object->getAssoc();
    }

    public function executeCommand($params, $context)
    {
        // Validate the RPC caller context.
        $this->validateMethodContext($context, ["role" => OMV_ROLE_ADMINISTRATOR]);
        // Validate the parameters of the RPC service method.
        $this->validateMethodParams($params, "rpc.borgbackup.executecommand");
        // Get the configuration object.
        $db = \OMV\Config\Database::getInstance();
        $object = $db->get("conf.service.borgbackup");

        // Create a background process.
        $bgStatusFilename = $this->createBgProcStatus();
        $pid = $this->fork();

        if ($pid > 0) { // Parent process.
            $this->initializeBgProcStatus($bgStatusFilename, $pid);
            return $bgStatusFilename;
        }
        $log = sprintf("[%s] omv-borgbackup-gui: INFO: %s - Manually started\r\n",
            date("Y-m-d H:i:s"), strtoupper($params['command'])
        );
        file_put_contents($this->getLogFile, $log, FILE_APPEND);

        // Child process.
        try {
            $bgOutputFilename = $this->createBgProcOutput();
            $this->updateBgProcStatus($bgStatusFilename, "outputfilename", $bgOutputFilename);

            switch ($params['command']) {
                case "scrub":
                    $cmd = sprintf("export LANG=C; %s %s -p %s 2>&1", $this->getProgram,
                        $params['command'], $object->get('percentscrub')
                    );
                    break;
                case "silent":
                    // Fix known silent errors - borgbackup -e fix && borgbackup scrub -p0
                    $cmd = sprintf("export LANG=C; %s -e fix && %s scrub -p0 2>&1",
                        $this->getProgram, $this->getProgram
                    );
                    break;
                case "undelete":
                    // undelete files - borgbackup fix -m [-f %FILENAME%]
                    if (empty($params['file'])) {
                        $cmd = sprintf("export LANG=C; %s fix -m 2>&1",
                            $this->getProgram
                        );
                    } else {
                        $cmd = sprintf("export LANG=C; %s fix -m -f %s 2>&1",
                            $this->getProgram, $params['file']
                        );
                    }
                    break;
                default:
                    $cmd = sprintf("export LANG=C; %s %s 2>&1",
                        $this->getProgram, $params['command']
                    );
            }
            $this->exec($cmd, $output, $bgOutputFilename);
            $this->finalizeBgProcStatus($bgStatusFilename, $output);
            $log = sprintf("[%s] omv-borgbackup-gui: INFO: %s - Finished\r\n",
                date("Y-m-d H:i:s"), strtoupper($params['command'])
            );
            file_put_contents($this->getLogFile, $log, FILE_APPEND);
            exit(0);
        } catch(\Exception $e) {
            $this->finalizeBgProcStatus($bgStatusFilename, "", $e);
            $log = sprintf("[%s] omv-borgbackup-gui: ERROR: %s - Error!\r\n",
                date("Y-m-d H:i:s"), strtoupper($params['command'])
            );
            file_put_contents($this->getLogFile, $log, FILE_APPEND);
            exit(1);
        }
    }
}

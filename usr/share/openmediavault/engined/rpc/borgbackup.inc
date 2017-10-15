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

class OMVRpcServiceBorgBackup extends \OMV\Rpc\ServiceAbstract
{
    private $getProgram = '/usr/bin/borg';
    private $getLogFile = '/var/log/borgbackup.log';

    public function getName()
    {
        return 'BorgBackup';
    }

    public function initialize()
    {
        $this->registerMethod('enumerateRepoCandidates');
        $this->registerMethod('getRepoList');
        $this->registerMethod('getRepo');
        $this->registerMethod('setRepo');
        $this->registerMethod('deleteRepo');

        $this->registerMethod('getArchiveList');
        $this->registerMethod('getArchive');
        $this->registerMethod('setArchive');
        $this->registerMethod('deleteArchive');
    }

    public function enumerateRepoCandidates($params, $context)
    {
        // Validate the RPC caller context.
        $this->validateMethodContext($context, ['role' => OMV_ROLE_ADMINISTRATOR]);
        // Get configuration data.
        $db = \OMV\Config\Database::getInstance();
        return $db->getAssoc('conf.service.borgbackup.repo');
    }

    public function getRepoList($params, $context)
    {
        // Validate the RPC caller context.
        $this->validateMethodContext($context, ['role' => OMV_ROLE_ADMINISTRATOR]);
        // Validate the parameters of the RPC service method.
        $this->validateMethodParams($params, 'rpc.common.getlist');
        // Get the configuration object.
        $db = \OMV\Config\Database::getInstance();
        $objects = $db->get('conf.service.borgbackup.repo');
        // Add additional share informations.
        $objectsAssoc = [];
        foreach ($objects as $objectk => &$objectv) {
            // Add the new property 'sharedfoldername'.
            $objectv->add('sharedfoldername', 'string', gettext("n/a"));
            if ($objectv->get('type') == 'local') {
                // Get the shared folder configuration object.
                $sfObject = $db->get('conf.system.sharedfolder',
                    $objectv->get('sharedfolderref'));
                // Update the 'sharedfoldername' property.
                $objectv->set('sharedfoldername', $sfObject->get('name'));
                $objectv->set('uri', gettext("n/a"));
            }
            $objectsAssoc[] = $objectv->getAssoc();
        }
        // Filter the result.
        return $this->applyFilter($objectsAssoc, $params['start'], $params['limit'],
            $params['sortfield'], $params['sortdir']);
    }

    public function getRepo($params, $context)
    {
        // Validate the RPC caller context.
        $this->validateMethodContext($context, ['role' => OMV_ROLE_ADMINISTRATOR]);
        // Validate the parameters of the RPC service method.
        $this->validateMethodParams($params, 'rpc.common.objectuuid');
        // Get the configuration object.
        $db = \OMV\Config\Database::getInstance();
        return $db->getAssoc('conf.service.borgbackup.repo', $params['uuid']);
    }

    public function setRepo($params, $context)
    {
        // Validate the RPC caller context.
        $this->validateMethodContext($context, ['role' => OMV_ROLE_ADMINISTRATOR]);
        // Validate the parameters of the RPC service method.
        $this->validateMethodParams($params, 'rpc.borgbackup.setrepo');
        // Prepare the configuration object.
        $object = new \OMV\Config\ConfigObject('conf.service.borgbackup.repo');
        // Remove spaces from name
        $params['name'] = str_replace(' ', '_', $params['name']);
        // Clear uri if type is local
        if ($params['type'] == 'local') {
            $params['uri'] = '';
        }
        $object->setAssoc($params);
        // Set the configuration object.
        $isNew = $object->isNew();
        $db = \OMV\Config\Database::getInstance();
        if (TRUE === $isNew) {
            // Check uniqueness - name, Shared folder or uri
            $db->assertIsUnique($object, 'name');
            if ($params['type'] == 'local') {
                $db->assertIsUnique($object, 'sharedfolderref');
            } else {
                $db->assertIsUnique($object, 'uri');
            }
        }
        $db->set($object);
        // initialize repo
        $cmdArgs = [];
        $cmdArgs[] = sprintf('BORG_PASSPHRASE=%s', $params['passphrase']);
        $cmdArgs[] = $this->getProgram;
        $cmdArgs[] = 'init';
        if ($params['encryption'] == true) {
            $cmdArgs[] = '--encryption=keyfile';
        } else {
            $cmdArgs[] = '--encryption=none';
        }
        if ($params['type'] == 'local') {
            $cmdArgs[] = \OMV\Rpc\Rpc::call("ShareMgmt", "getPath", [
                "uuid" => $params['sharedfolderref']
            ], $context);
        } else {
            $cmdArgs[] = $params['uri'];
        }
        $cmd = new \OMV\System\Process($cmdArgs);
        $cmd->execute($output);
        // Return the configuration object.
        return $object->getAssoc();
    }

    public function deleteRepo($params, $context)
    {
        // Validate the RPC caller context.
        $this->validateMethodContext($context, ['role' => OMV_ROLE_ADMINISTRATOR]);
        // Validate the parameters of the RPC service method.
        $this->validateMethodParams($params, 'rpc.common.objectuuid');
        // Delete the configuration object.
        $db = \OMV\Config\Database::getInstance();
        $object = $db->get('conf.service.borgbackup.repo', $params['uuid']);
        $db->delete($object);
        // Return the deleted configuration object.
        return $object->getAssoc();
    }

    public function getArchiveList($params, $context)
    {
        // Validate the RPC caller context.
        $this->validateMethodContext($context, ['role' => OMV_ROLE_ADMINISTRATOR]);
        // Validate the parameters of the RPC service method.
        $this->validateMethodParams($params, 'rpc.common.getlist');
        // Get configuration data.
        $db = \OMV\Config\Database::getInstance();
        $objects = $db->getAssoc('conf.service.borgbackup.archive');
        // Filter the result.
        return $this->applyFilter($objects, $params['start'], $params['limit'],
            $params['sortfield'], $params['sortdir']);
    }

    public function getArchive($params, $context)
    {
        // Validate the RPC caller context.
        $this->validateMethodContext($context, ['role' => OMV_ROLE_ADMINISTRATOR]);
        // Validate the parameters of the RPC service method.
        $this->validateMethodParams($params, 'rpc.common.objectuuid');
        // Get the configuration object.
        $db = \OMV\Config\Database::getInstance();
        return $db->getAssoc('conf.service.borgbackup.archive', $params['uuid']);
    }

    public function setArchive($params, $context)
    {
        // Validate the RPC caller context.
        $this->validateMethodContext($context, ['role' => OMV_ROLE_ADMINISTRATOR]);
        // Validate the parameters of the RPC service method.
        $this->validateMethodParams($params, 'rpc.borgbackup.setarchive');
        // Prepare the configuration object.
        $object = new \OMV\Config\ConfigObject('conf.service.borgbackup.archive');
        // Remove spaces from name
        $params['name'] = str_replace(' ', '_', $params['name']);
        $object->setAssoc($params);
        // Set the configuration object.
        $isNew = $object->isNew();
        $db = \OMV\Config\Database::getInstance();
        if (TRUE === $isNew) {
            // Check uniqueness - Shared folder
            $db->assertIsUnique($object, 'name');
        }
        $db->set($object);
        // create archive
        $repo = $db->get('conf.service.borgbackup.repo', $params['reporef']);
        $cmdArgs = [];
        $cmdArgs[] = sprintf('BORG_PASSPHRASE=%s', $repo->get('passphrase'));
        $cmdArgs[] = $this->getProgram;
        $cmdArgs[] = 'create';
        $cmdArgs[] = sprintf('--compression %s,%s', $params['compressiontype'], $params['compressionratio']);
        if ($repo->get('type') == 'local') {
            $path = \OMV\Rpc\Rpc::call("ShareMgmt", "getPath", [
                "uuid" => $repo->get('sharedfolderref')
            ], $context);
        } else {
            $path = $repo->get['uri'];
        }
        $cmdArgs[] = sprintf('%s::%s', $path, $params['name']);
        $includes = explode(',', $params['include']);
        foreach ($includes as $dirs) {
            $cmdArgs[] = escapeshellarg($dirs);
        }
        $excludes = explode(',', $params['exclude']);
        foreach ($excludes as $dirs) {
            $cmdArgs[] = sprintf('--exclude %s', escapeshellarg($dirs));
        }
        if ($params['onefs'] == true) {
            $cmdArgs[] = '--one-file-system';
        }
        if ($params['noatime'] == true) {
            $cmdArgs[] = '--noatime';
        }
        $cmd = new \OMV\System\Process($cmdArgs);
        $cmd->setRedirect2to1();
        $cmd->setBackground(TRUE);
        $cmd->execute($output);
        // Return the configuration object.
        return $object->getAssoc();
    }

    public function deleteArchive($params, $context)
    {
        // Validate the RPC caller context.
        $this->validateMethodContext($context, ['role' => OMV_ROLE_ADMINISTRATOR]);
        // Validate the parameters of the RPC service method.
        $this->validateMethodParams($params, 'rpc.common.objectuuid');
        // Delete the configuration object.
        $db = \OMV\Config\Database::getInstance();
        $object = $db->get('conf.service.borgbackup.archive', $params['uuid']);
        $db->delete($object);
        // Return the deleted configuration object.
        return $object->getAssoc();
    }
}

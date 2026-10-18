"""Fire the events the collectors listen to and check what reaches the queue."""
import unittest
from pathlib import Path

from lupa import LuaRuntime

from transport_test import ordinary_lua

ROOT = Path(__file__).resolve().parents[1]


class CollectorTests(unittest.TestCase):
    def setUp(self):
        self.lua = LuaRuntime(unpack_returned_tuples=True)
        self.lua.execute('''
            handlers = {}; queued = {}; invoking = 'monitor'
            function exports(name, fn) end
            function GetCurrentResourceName() return 'vanish_logger' end
            function GetInvokingResource() return invoking end
            function GetResourceMetadata() return '1.2.0' end
            function GetResourceState() return 'missing' end
            function GetGameTimer() return clock or 0 end function CreateThread() end function Wait() end
            function AddEventHandler(name, fn) handlers[name] = fn end
            function GetPlayerName(id) if id == 4 then return 'Four' end end
            function GetNumPlayerIdentifiers() return 1 end
            function GetPlayerIdentifier() return 'license:four' end
        ''')
        self.lua.execute((ROOT / 'config.lua').read_text())
        self.lua.execute((ROOT / 'server/limits.lua').read_text())
        self.lua.execute(ordinary_lua((ROOT / 'server/util.lua').read_text()))
        for name in ('framework/esx', 'collectors/connections', 'collectors/esx',
                     'collectors/txadmin', 'collectors/doors'):
            self.lua.execute((ROOT / f'bridge/{name}.lua').read_text())
        self.lua.execute(ordinary_lua((ROOT / 'server/shaping.lua').read_text()))
        self.lua.execute((ROOT / 'server/api.lua').read_text())
        self.lua.execute('SetTransport({ Enqueue = function(_, p) queued[#queued + 1] = p; return true end })')

    def fire(self, name, *args):
        self.lua.globals().handlers[name](*args)
        queued = self.lua.globals().queued
        return queued[len(queued)] if len(queued) else None

    def table(self, value):
        return self.lua.table_from(value, recursive=True)

    def test_txadmin_ban_names_the_admin_and_the_offline_player(self):
        event = self.fire('txAdmin:events:playerBanned', self.table({
            'author': 'StaffMember', 'reason': 'RDM', 'expiration': False, 'actionId': 'A1',
            'targetName': 'Offender', 'targetIds': ['license:abc', 'discord:123', 'ip:1.2.3.4'],
        }))
        self.assertEqual((event.category, event.action, event.severity), ('staff', 'ban', 'notice'))
        self.assertEqual(event.actor.name, 'StaffMember')
        self.assertEqual(event.target.license, 'license:abc')
        self.assertEqual(event.target.discord, 'discord:123')
        self.assertIsNone(event.target.ip)
        self.assertEqual(event.data.duration, 'permanent')
        self.assertEqual(event.context.resource, 'txAdmin')

    def test_txadmin_events_from_another_resource_are_ignored(self):
        self.lua.globals().invoking = 'some_cheat_menu'
        self.assertIsNone(self.fire('txAdmin:events:playerBanned', self.table({'author': 'x'})))
        self.assertIsNone(self.fire('txsv:logger:menuEvent', 4, 'spawnVehicle', True, 'adder'))

    def test_menu_actions_map_to_staff_actions_and_refusals_to_security(self):
        event = self.fire('txsv:logger:menuEvent', 4, 'spawnVehicle', True, 'adder')
        self.assertEqual((event.action, event.data.model), ('vehicle_spawn', 'adder'))
        self.assertEqual(event.actor.license, 'license:four')
        event = self.fire('txsv:logger:menuEvent', 4, 'setOnFire', True, 4)
        self.assertEqual((event.action, event.severity), ('command_executed', 'notice'))
        self.assertEqual(event.data.command, 'txAdmin menu: setOnFire')
        event = self.fire('txsv:logger:menuEvent', 4, 'healAll', False, None)
        self.assertEqual((event.category, event.action), ('security', 'unauthorized_event'))

    def test_restart_countdown_logs_only_the_final_minute(self):
        self.assertIsNone(self.fire('txAdmin:events:scheduledRestart', self.table({'secondsRemaining': 600})))
        event = self.fire('txAdmin:events:scheduledRestart', self.table({'secondsRemaining': 60}))
        self.assertEqual(event.action, 'server_restart')

    def test_money_is_logged_with_the_script_that_moved_it(self):
        self.lua.globals().invoking = 'es_extended'
        event = self.fire('esx:addAccountMoney', 4, 'black_money', 500, 'sale', 'vanish_selldrugs')
        self.assertEqual((event.category, event.action), ('money', 'dirty_added'))
        self.assertEqual((event.data.amount, event.data.account), (500, 'black_money'))
        self.assertEqual(event.context.resource, 'vanish_selldrugs')
        event = self.fire('esx:addAccountMoney', 4, 'bank', 300, 'Paycheck', 'es_extended')
        self.assertEqual(event.action, 'salary')
        event = self.fire('esx:removeAccountMoney', 4, 'money', 20, 'fuel', None)
        self.assertEqual((event.action, event.context.resource), ('cash_removed', 'es_extended'))

    def test_cash_resyncs_from_inventory_moves_are_not_double_logged(self):
        self.assertIsNone(self.fire('esx:setAccountMoney', 4, 'money', 980, 'Sync account with item'))
        event = self.fire('esx:setAccountMoney', 4, 'bank', 1000, 'Government Grant', 'es_extended')
        self.assertEqual((event.action, event.data.amount), ('balance_set', 1000))

    def test_disconnects_carry_the_reason(self):
        self.lua.execute('source = 4')
        event = self.fire('playerDropped', 'Exiting')
        self.assertEqual((event.action, event.data.reason), ('disconnect', 'Exiting'))

    def test_autolocks_are_not_logged_as_players(self):
        self.assertIsNone(self.fire('ox_doorlock:stateChanged', None, 3, True))
        event = self.fire('ox_doorlock:stateChanged', 4, 3, False, 'lockpick')
        self.assertEqual((event.category, event.action, event.data.item), ('property', 'door_unlocked', 'lockpick'))


if __name__ == '__main__':
    unittest.main()

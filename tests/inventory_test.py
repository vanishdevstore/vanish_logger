"""Exercise the real inventory hook and ESX bridge with FiveM natives stubbed."""
import unittest
from pathlib import Path

from lupa import LuaRuntime

ROOT = Path(__file__).resolve().parents[1]


class InventoryTests(unittest.TestCase):
    def setUp(self):
        self.lua = LuaRuntime(unpack_returned_tuples=True)
        self.lua.execute('''
            handlers = {}; events = {}
            function GetResourceState() return 'started' end
            function GetCurrentResourceName() return 'vanish_logger' end
            function CreateThread(fn) fn() end
            function AddEventHandler(name, fn) handlers[name] = fn end
            function Debug() end
            function NewId() return 'transaction' end
            function ShortText(value)
                if type(value) == 'number' then value = tostring(value) end
                if type(value) ~= 'string' or value == '' then return nil end
                return value
            end
            function GetPlayerName(id)
                if id == 6 or id == 2 then return 'Account ' .. id end
            end
            function GetIdentifiers(id)
                if GetPlayerName(id) then
                    return { source = id, name = GetPlayerName(id), license = 'license:' .. id }
                end
            end
            function LogEvent(event) events[#events + 1] = event end
            inventories = { [15] = { id = 15, type = 'player', owner = 'char1:player15' } }
            exports = {
                ox_inventory = {
                    registerHook = function(_, name) return name end,
                    GetInventory = function(_, id) return inventories[id] or false end,
                },
                es_extended = { getSharedObject = function()
                    return { GetPlayerFromId = function(id)
                        if not GetPlayerName(id) then return nil end
                        return {
                            identifier = 'char1:player' .. id,
                            getName = function() return id == 6 and 'CJ Jones' or 'Recipient Name' end,
                            job = { name = 'bcso' }, getGroup = function() return 'user' end
                        }
                    end }
                end }
            }
        ''')
        self.lua.execute((ROOT / 'config.lua').read_text())
        self.lua.globals().Config.inventory.coords = False
        self.lua.execute((ROOT / 'bridge/framework/esx.lua').read_text())
        self.lua.execute((ROOT / 'bridge/inventory/ox_inventory.lua').read_text())

    def transfer(self, recipient=2, sender=6, to_type='player', success=True):
        payload = self.lua.table_from({
            'source': 6, 'action': 'give', 'fromInventory': sender,
            'toInventory': recipient, 'fromType': 'player', 'toType': to_type,
            'count': 10000, 'fromSlot': {'name': 'money', 'label': 'Money', 'slot': 23},
        }, recursive=True)
        self.lua.globals().handlers.swapItems(success, payload)
        return self.lua.globals().events[1]

    def test_money_give_resolves_recipient_server_id(self):
        for recipient in (2, '2'):
            with self.subTest(recipient=recipient):
                self.setUp()
                event = self.transfer(recipient)
                self.assertEqual(event.action, 'player_to_player_transfer')
                self.assertEqual(event.actor.name, 'CJ Jones')
                self.assertEqual(event.target.name, 'Recipient Name')
                self.assertEqual(event.target.source, 2)
                self.assertEqual(event.target.characterId, 'char1:player2')
                self.assertEqual(event.target.license, 'license:2')
                self.assertEqual(event.data.quantity, 10000)
                self.assertEqual(event.context.toInventory.id, '2')

    def test_owner_identifier_fallback_is_preserved(self):
        self.assertEqual(self.transfer('char1:offline').target.characterId, 'char1:offline')

    def test_disconnected_server_id_falls_back_to_inventory_owner(self):
        # ox_inventory defers hook post-events, so the recipient can already be
        # unresolvable by the time the event is built. The inventory still
        # carries the persistent owner.
        for recipient in (15, '15'):
            self.setUp()
            target = self.transfer(recipient).target
            self.assertEqual(target.characterId, 'char1:player15')
            self.assertEqual(target.identifier, 'char1:player15')
            self.assertIsNone(target.source)

    def test_ownerless_inventory_does_not_become_character_id(self):
        self.lua.execute("inventories[15] = { id = 15, type = 'drop', owner = false }")
        self.assertIsNone(self.transfer(15).target)

    def test_disconnected_server_id_does_not_become_character_id(self):
        for recipient in (99, '99'):
            self.setUp()
            self.assertIsNone(self.transfer(recipient).target)

    def test_self_move_has_no_target(self):
        self.assertIsNone(self.transfer('6').target)

    def test_non_player_inventory_has_no_target(self):
        self.assertIsNone(self.transfer('stash_test', to_type='stash').target)

    def test_failed_transfer_is_not_logged(self):
        self.assertIsNone(self.transfer(success=False))


if __name__ == '__main__':
    unittest.main()

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
            function BoundedCopy(value) return value end
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

    def create(self, inventory_id=15, created_by='Sync_DrugsCreator', success=True,
               item_name='drug_yerkys'):
        """Fire ox_inventory's createItem hook the way a script granting an item does."""
        payload = self.lua.table_from({
            'inventoryId': inventory_id,
            'resource': created_by,
            'count': 3,
            'item': {'name': item_name, 'label': 'Yerkys'},
        }, recursive=True)
        self.lua.globals().handlers.createItem(success, payload)
        return self.lua.globals().events[1]

    # The whole point of logging item creation is answering "where did this
    # come from". ox_inventory is the plumbing every item passes through, so
    # naming it as the resource answers nothing; the script that called for the
    # item is the attribution worth storing, and the platform already indexes
    # `resource` as a searchable subject.
    def test_created_item_names_the_script_that_made_it(self):
        self.assertEqual(self.create(created_by='Sync_DrugsCreator').resource,
                         'Sync_DrugsCreator')

    def test_created_item_falls_back_to_ox_inventory_when_unattributed(self):
        self.assertEqual(self.create(created_by=None).resource, 'ox_inventory')

    # `inventoryId` arrives as a number for a player inventory, and the owner
    # lookup only accepted strings — so every created item logged with no actor
    # at all and rendered as "Someone received ...".
    def test_created_item_resolves_the_owner_of_a_numeric_inventory(self):
        for inventory_id in (15, '15'):
            self.setUp()
            actor = self.create(inventory_id).actor
            self.assertIsNotNone(actor, 'a numeric inventory id must still resolve an owner')
            self.assertEqual(actor.characterId, 'char1:player15')

    def test_created_item_resolves_a_connected_player(self):
        self.assertEqual(self.create(6).actor.name, 'CJ Jones')

    def test_created_item_without_a_known_owner_has_no_actor(self):
        self.lua.execute("inventories[15] = { id = 15, type = 'drop', owner = false }")
        self.assertIsNone(self.create(15).actor)

    def test_failed_creation_is_not_logged(self):
        self.assertIsNone(self.create(success=False))

    # Volume control at the source. A production loop can emit tens of
    # thousands of creations an hour, and they are worth nothing to an
    # investigation; dropping them here costs no bandwidth and no ingest work.
    def test_ignored_sources_are_not_logged(self):
        self.lua.execute("Config.inventory.ignoreCreatedBy = { 'Sync_DrugsCreator' }")
        self.assertIsNone(self.create(created_by='Sync_DrugsCreator'))

    def test_ignoring_a_source_leaves_the_others_alone(self):
        self.lua.execute("Config.inventory.ignoreCreatedBy = { 'Sync_DrugsCreator' }")
        self.assertEqual(self.create(created_by='palms_blackmarket').resource,
                         'palms_blackmarket')

    # Resource names get typed into a config by hand; a casing slip that
    # silently keeps a firehose running is a bad way to find out.
    def test_ignoring_a_source_is_case_insensitive(self):
        self.lua.execute("Config.inventory.ignoreCreatedBy = { 'sync_drugscreator' }")
        self.assertIsNone(self.create(created_by='Sync_DrugsCreator'))

    # A production loop is noise; a gun coming out of one is not. Volume is
    # not the reason to keep weapon creation - 553 in six hours against 70,000
    # item creations - the reason is that it is the row an investigation
    # starts from.
    def test_weapon_creation_survives_an_ignored_source(self):
        self.lua.execute("Config.inventory.ignoreCreatedBy = { 'Sync_DrugsCreator' }")
        event = self.create(created_by='Sync_DrugsCreator', item_name='WEAPON_PISTOL')
        self.assertIsNotNone(event, 'weapon creation must never be dropped by the ignore list')
        self.assertEqual(event.action, 'weapon_added')
        self.assertEqual(event.resource, 'Sync_DrugsCreator')

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

    def test_non_player_inventory_has_no_target(self):
        self.assertIsNone(self.transfer('stash_test', to_type='stash').target)

    def test_failed_transfer_is_not_logged(self):
        self.assertIsNone(self.transfer(success=False))

    def shuffles(self):
        self.lua.globals().Config.inventory.slotShuffles = True

    def test_slot_shuffle_is_not_logged(self):
        self.assertIsNone(self.transfer('6'))

    def test_slot_shuffle_is_dropped_whatever_the_id_type(self):
        for sender, recipient in ((6, '6'), ('6', 6), ('stash_a', 'stash_a')):
            self.setUp()
            self.assertIsNone(self.transfer(recipient, sender=sender))

    def test_a_real_move_survives_the_shuffle_guard(self):
        self.assertIsNotNone(self.transfer(2))

    def test_drop_is_not_mistaken_for_a_shuffle(self):
        payload = self.lua.table_from({
            'source': 6, 'action': 'move', 'fromInventory': 6,
            'dropId': 'drop-1', 'fromType': 'player', 'toType': 'newdrop', 'count': 1,
            'fromSlot': {'name': 'water', 'label': 'Water', 'slot': 3},
        }, recursive=True)
        self.lua.globals().handlers.swapItems(True, payload)
        self.assertEqual(self.lua.globals().events[1].action, 'item_dropped')

    def test_shuffles_are_logged_when_the_option_is_on(self):
        self.shuffles()
        self.assertIsNotNone(self.transfer('6'))

    def test_self_move_has_no_target(self):
        self.shuffles()
        self.assertIsNone(self.transfer('6').target)


if __name__ == '__main__':
    unittest.main()

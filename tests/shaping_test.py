"""Folding repeats and the per-player ceiling, through the real LogEvent."""
import unittest
from pathlib import Path

from lupa import LuaRuntime

from transport_test import ordinary_lua

ROOT = Path(__file__).resolve().parents[1]


class ShapingTests(unittest.TestCase):
    def setUp(self):
        self.lua = LuaRuntime(unpack_returned_tuples=True)
        self.lua.execute('''
            clock = 0; sent = {}
            function GetGameTimer() return clock end
            function CreateThread() end
            function Wait() end
            function exports() end
            function GetCurrentResourceName() return 'vanish_logger' end
            function GetInvokingResource() return 'some_job' end
            function GetResourceMetadata() return '1.3.0' end
            function GetResourceState() return 'missing' end
            function AddEventHandler() end
            function GetPlayerName(id) if id == 7 or id == 8 then return 'Player ' .. id end end
            function GetNumPlayerIdentifiers() return 0 end
        ''')
        self.lua.execute((ROOT / 'config.lua').read_text())
        self.lua.execute((ROOT / 'server/limits.lua').read_text())
        self.lua.execute(ordinary_lua((ROOT / 'server/util.lua').read_text()))
        self.lua.execute((ROOT / 'bridge/framework/esx.lua').read_text())
        self.lua.execute(ordinary_lua((ROOT / 'server/shaping.lua').read_text()))
        self.lua.execute((ROOT / 'server/api.lua').read_text())
        self.lua.execute('SetTransport({ Enqueue = function(_, p) sent[#sent + 1] = p; return true end })')
        self.g = self.lua.globals()

    def pay(self, amount, actor=7, reason='job payout', account='money'):
        self.lua.execute(f'''
            LogEvent({{ category = 'money', action = 'cash_added', actor = {actor},
                data = {{ account = '{account}', amount = {amount}, reason = '{reason}' }} }})
        ''')

    def sent(self):
        return [self.g.sent[i] for i in range(1, len(self.g.sent) + 1)]

    def advance(self, ms):
        self.g.clock = self.g.clock + ms
        self.g.Shaper.Sweep(self.g.clock)

    def test_the_first_event_is_sent_at_once_and_repeats_as_one_total(self):
        for amount in (50, 75, 25, 100):
            self.pay(amount)
            self.advance(2000)
        self.assertEqual(len(self.sent()), 1)
        self.assertEqual(self.sent()[0].data.amount, 50)

        self.advance(10000)
        rows = self.sent()
        self.assertEqual(len(rows), 2)
        self.assertEqual(rows[1].action, 'cash_added')
        self.assertEqual(rows[1].data.amount, 200)
        self.assertEqual(rows[1].data.repeats, 3)
        self.assertEqual(rows[1].data.reason, 'job payout')
        self.assertNotEqual(rows[1].eventId, rows[0].eventId)

    def test_different_reasons_players_and_accounts_are_never_folded(self):
        self.pay(10)
        self.pay(10, reason='fuel refund')
        self.pay(10, actor=8)
        self.pay(10, account='bank')
        self.assertEqual(len(self.sent()), 4)
        self.advance(20000)
        self.assertEqual(len(self.sent()), 4)

    def test_a_loop_that_never_pauses_is_two_rows_a_minute_and_loses_nothing(self):
        # One payout a second for 130 s: each minute is its first payout plus
        # one row totalling the rest, instead of 60 rows.
        for _ in range(130):
            self.pay(5)
            self.advance(1000)
        self.assertEqual(len(self.sent()), 5)
        self.lua.execute('Shaper.FlushAll()')
        rows = self.sent()
        self.assertEqual(len(rows), 6)
        self.assertEqual(sum(row.data.amount for row in rows), 5 * 130)

    def test_a_flooding_player_is_capped_and_reported_once(self):
        limit = self.g.Config.perPlayerPerMinute
        for i in range(limit + 50):
            self.pay(1, reason=f'unique {i}')
        self.pay(1, actor=8)
        rows = self.sent()
        self.assertEqual(len(rows), limit + 1)
        self.assertEqual(self.g.Shaper.Status().limited, 50)

        self.advance(60000)
        report = [row for row in self.sent() if row.category == 'security']
        self.assertEqual(len(report), 1)
        self.assertEqual(report[0].action, 'rate_limit_triggered')
        self.assertEqual(report[0].data.dropped, 50)
        self.assertEqual(report[0].actor.source, 7)

    def test_folding_can_be_turned_off(self):
        self.g.Config.coalesce.window = 0
        for _ in range(5): self.pay(10)
        self.assertEqual(len(self.sent()), 5)

    def test_volume_counts_what_was_sent(self):
        for _ in range(3): self.pay(10)
        self.pay(10, reason='other')
        self.advance(20000)
        rows, _ = self.g.Shaper.Top(5)
        self.assertEqual(rows[1].label, 'money cash_added')
        self.assertEqual(rows[1].count, 3)


if __name__ == '__main__':
    unittest.main()

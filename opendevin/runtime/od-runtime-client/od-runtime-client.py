# from opendevin.runtime.plugins import PluginRequirement
# from opendevin.runtime.tools import RuntimeTool
# from typing import Any
import asyncio
import websockets
from opendevin.events.action.action import Action
import pexpect
import json
from websockets.exceptions import ConnectionClosed
from opendevin.events.serialization import event_to_dict, event_from_dict
from opendevin.events.observation import Observation
from opendevin.events.action import (
    Action,
    AgentRecallAction,
    BrowseInteractiveAction,
    BrowseURLAction,
    CmdRunAction,
    FileReadAction,
    FileWriteAction,
    IPythonRunCellAction,
)
from opendevin.events.serialization.action import ACTION_TYPE_TO_CLASS
from opendevin.events.event import Event
from opendevin.events.observation import (
    CmdOutputObservation,
    ErrorObservation,
    Observation,
    IPythonRunCellObservation
)

class RuntimeClient:
    def __init__(self) -> None:
        self.init_websocket()
        self.init_shell()

    # def init_sandbox_plugins(self, plugins: list[PluginRequirement]) -> None:
    #     print("Not implemented yet.")
    
    # def init_runtime_tools(self, runtime_tools: list[RuntimeTool], runtime_tools_config: dict[RuntimeTool, Any] | None = None, is_async: bool = True) -> None:
    #     print("Not implemented yet.")

    def init_websocket(self) -> None:
        server = websockets.serve(self.listen, "0.0.0.0", 8080)
        loop = asyncio.get_event_loop()
        loop.run_until_complete(server)
        loop.run_forever()
    
    def init_shell(self) -> None:
        self.shell = pexpect.spawn('/bin/bash', encoding='utf-8')
        self.shell.expect(r'[$#] ')

    async def listen(self, websocket):
        try:
            async for message in websocket:
                event_str = json.loads(message)
                event = event_from_dict(event_str)
                if isinstance(event, Action):
                    observation = await self.run_action(event)
                    await websocket.send(json.dumps(event_to_dict(observation)))
        except ConnectionClosed:
            print("Connection closed")
    
    async def run_action(self, action) -> Observation:
        action_type = action.action  # type: ignore[attr-defined]
        observation = await getattr(self, action_type)(action)
        observation._parent = action.id  # type: ignore[attr-defined]
        return observation
                
    def execute_command(self, command):
        print(f"Received command: {command}")
        self.shell.sendline(command)
        self.shell.expect(r'[$#] ')
        output = self.shell.before.strip().split('\r\n', 1)[1].strip()
        exit_code = output[-1].strip()
        return output, exit_code
                    
    async def run(self, action: CmdRunAction) -> Observation:
        return self._run_command(action.command)
    
    def _run_command(self, command: str) -> Observation:
        try:
            output, exit_code = self.execute_command(command)
            return CmdOutputObservation(
                command_id=-1, content=str(output), command=command, exit_code=exit_code
            )
        except UnicodeDecodeError:
            return ErrorObservation('Command output could not be decoded as utf-8')

    async def run_ipython(self, action: IPythonRunCellAction) -> Observation:
        obs = self._run_command(
            ("cat > /tmp/opendevin_jupyter_temp.py <<'EOL'\n" f'{action.code}\n' 'EOL'),
        )

        # run the code
        obs = self._run_command('cat /tmp/opendevin_jupyter_temp.py | execute_cli')
        output = obs.content
        if 'pip install' in action.code:
            print(output)
            package_names = action.code.split(' ', 2)[-1]
            is_single_package = ' ' not in package_names

            if 'Successfully installed' in output:
                restart_kernel = 'import IPython\nIPython.Application.instance().kernel.do_shutdown(True)'
                if (
                    'Note: you may need to restart the kernel to use updated packages.'
                    in output
                ):
                    self._run_command(
                        (
                            "cat > /tmp/opendevin_jupyter_temp.py <<'EOL'\n"
                            f'{restart_kernel}\n'
                            'EOL'
                        )
                    )
                    obs = self._run_command(
                        'cat /tmp/opendevin_jupyter_temp.py | execute_cli'
                    )
                    output = '[Package installed successfully]'
                    if "{'status': 'ok', 'restart': True}" != obs.content.strip():
                        print(obs.content)
                        output += (
                            '\n[But failed to restart the kernel to load the package]'
                        )
                    else:
                        output += (
                            '\n[Kernel restarted successfully to load the package]'
                        )

                    # re-init the kernel after restart
                    if action.kernel_init_code:
                        obs = self._run_command(
                            (
                                f"cat > /tmp/opendevin_jupyter_init.py <<'EOL'\n"
                                f'{action.kernel_init_code}\n'
                                'EOL'
                            ),
                        )
                        obs = self._run_command(
                            'cat /tmp/opendevin_jupyter_init.py | execute_cli',
                        )
            elif (
                is_single_package
                and f'Requirement already satisfied: {package_names}' in output
            ):
                output = '[Package already installed]'
        return IPythonRunCellObservation(content=output, code=action.code)

    def close(self):
        self.shell.close()

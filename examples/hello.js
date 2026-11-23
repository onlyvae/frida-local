send({ message: 'Frida 脚本已加载', pid: Process.id, architecture: Process.arch });
console.log('Frida Local 测试会话已启动');

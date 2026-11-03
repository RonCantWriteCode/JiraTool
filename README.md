win版打包命令
dotnet publish -c Release -r win-x64 --self-contained true -p:PublishSingleFile=true -o publish


mac版打包命令

cd /Volumes/Work/github/JiraTool/JiraMacTool

打包命令
bash build_app.sh

编译命令
swift build -c release